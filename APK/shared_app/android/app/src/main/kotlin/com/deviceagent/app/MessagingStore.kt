package com.deviceagent.app

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.notification.StatusBarNotification

/** Native-side messaging error -> Flutter `PlatformException.code`. */
class MessagingException(val code: String, message: String) : Exception(message)

/**
 * P1-06 (messaging adapters): provider-specific read/reply, **notification
 * inline-reply** ke zariye (koi app ka private API / UI-scraping nahi).
 *
 * Honest design / limits:
 *  - Sirf [SUPPORTED_PACKAGES] — baaki apps `UNSUPPORTED_TARGET`
 *    (audit: "Unsupported target => CAPABILITY_UNAVAILABLE").
 *  - Reply tabhi ho sakti hai jab app ki notification mein inline-reply
 *    (RemoteInput) action ho **aur notification abhi screen/shade mein ho**;
 *    dismiss hone par event `gone` => reply `NOT_FOUND`.
 *  - Do-step: `prepareReply` (draft, 5 min TTL) -> `sendReply(draftId)`
 *    (single-use). Send "app ko handoff" hai — delivery confirm nahi hoti.
 *  - Sab kuch **sirf memory mein** (max [MAX_EVENTS]); disk par kuch nahi.
 *  - Reply rate limit: [MAX_REPLIES_PER_MIN]/minute.
 */
object MessagingStore {
    const val MAX_EVENTS = 50
    const val MAX_TEXT = 500
    const val MAX_REPLY_CHARS = 1000
    private const val MAX_DRAFTS = 20
    private const val DRAFT_TTL_MS = 5 * 60 * 1000L
    private const val MAX_REPLIES_PER_MIN = 5

    /** package -> display naam. Naya provider = yahan ek line + test. */
    val SUPPORTED_PACKAGES: Map<String, String> = mapOf(
        "com.whatsapp" to "WhatsApp",
        "com.whatsapp.w4b" to "WhatsApp Business",
        "org.telegram.messenger" to "Telegram",
        "org.thoughtcrime.securesms" to "Signal",
        "com.facebook.orca" to "Messenger",
        "com.google.android.apps.messaging" to "Google Messages (SMS/RCS)",
        "com.samsung.android.messaging" to "Samsung Messages (SMS)",
    )

    private class Event(
        val id: String,
        val key: String,
        val pkg: String,
        val sender: String?,
        val text: String?,
        val postedAtMs: Long,
        val replyAction: Notification.Action?,
        val remoteInput: RemoteInput?,
        @Volatile var gone: Boolean = false,
    ) {
        val canReply: Boolean get() = !gone && replyAction != null && remoteInput != null
    }

    private class Draft(val id: String, val eventId: String, val text: String, val createdAtMs: Long)

    private val lock = Any()
    private val events = LinkedHashMap<String, Event>()   // id -> event
    private val drafts = LinkedHashMap<String, Draft>()   // id -> draft
    private val replyTimes = ArrayDeque<Long>()

    /** User ne app block kiya — uske events/drafts hata do (reply bhi nahi jayegi). */
    fun purgePackages(blocked: Set<String>) = synchronized(lock) {
        val ids = events.filterValues { it.pkg in blocked }.keys.toList()
        ids.forEach { events.remove(it) }
        drafts.entries.removeAll { it.value.eventId in ids }
    }

    /**
     * Notification key -> stable event id. Pehle `key.hashCode()` (32-bit) tha:
     * do alag conversations ka hash takra jaye to ek event doosre ko overwrite
     * kar deta aur `prepareReply/sendReply` GALAT conversation mein chala
     * jata (wrong-recipient). Ab SHA-256 ke pehle 8 bytes (64-bit).
     */
    private fun eventId(key: String): String {
        val d = java.security.MessageDigest.getInstance("SHA-256")
            .digest(key.toByteArray(Charsets.UTF_8))
        return "msg_" + d.take(8).joinToString("") { "%02x".format(it) }
    }

    // ---- Listener hooks ---------------------------------------------------

    fun onPosted(n: StatusBarNotification) {
        if (!SUPPORTED_PACKAGES.containsKey(n.packageName)) return
        val notif = n.notification
        if (notif.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = notif.extras
        val sender = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val text = extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()

        var action: Notification.Action? = null
        var input: RemoteInput? = null
        notif.actions?.forEach { a ->
            if (action == null) {
                val ri = a.remoteInputs?.firstOrNull { it.allowFreeFormInput }
                if (ri != null) {
                    action = a
                    input = ri
                }
            }
        }
        val id = eventId(n.key)
        synchronized(lock) {
            events.remove(id) // update => naya event aakhir mein
            events[id] = Event(
                id, n.key, n.packageName, sender?.take(MAX_TEXT), text?.take(MAX_TEXT),
                n.postTime, action, input,
            )
            while (events.size > MAX_EVENTS) {
                events.remove(events.keys.first())
            }
        }
    }

    fun onRemoved(key: String) = synchronized(lock) {
        events[eventId(key)]?.gone = true
    }

    /** Listener disconnect => PendingIntents ka bharosa nahi. */
    fun clear() = synchronized(lock) {
        events.clear()
        drafts.clear()
    }

    // ---- Query / reply API ------------------------------------------------

    fun getEvents(limit: Int, sinceMs: Long, pkg: String?): List<Map<String, Any?>> {
        // Unsupported app ke liye chup-chaap khaali list nahi — saaf
        // UNSUPPORTED_TARGET (Dart ise CAPABILITY_UNAVAILABLE banata hai).
        if (pkg != null && !SUPPORTED_PACKAGES.containsKey(pkg)) {
            throw MessagingException("UNSUPPORTED_TARGET", "\"$pkg\" supported messaging app nahi hai")
        }
        return getEventsInternal(limit, sinceMs, pkg)
    }

    private fun getEventsInternal(limit: Int, sinceMs: Long, pkg: String?): List<Map<String, Any?>> =
        synchronized(lock) {
            events.values.toList().asReversed()
                .filter { it.postedAtMs > sinceMs && (pkg == null || it.pkg == pkg) }
                .take(limit.coerceIn(1, MAX_EVENTS))
                .map {
                    mapOf(
                        "event_id" to it.id,
                        "package" to it.pkg,
                        "app" to SUPPORTED_PACKAGES[it.pkg],
                        "sender" to it.sender,
                        "text" to it.text,
                        "posted_at_ms" to it.postedAtMs,
                        "can_reply" to it.canReply,
                    )
                }
        }

    fun prepareReply(eventId: String, rawText: String, now: Long = System.currentTimeMillis()): Map<String, Any?> {
        val text = rawText.trim()
        if (text.isEmpty()) throw MessagingException("INVALID_REQUEST", "Reply text khaali hai")
        if (text.length > MAX_REPLY_CHARS) {
            throw MessagingException("TOO_LONG", "Reply $MAX_REPLY_CHARS characters se chhota hona chahiye")
        }
        synchronized(lock) {
            pruneDrafts(now)
            val ev = events[eventId]
                ?: throw MessagingException("NOT_FOUND", "Event nahi mila ya expire ho gaya")
            if (ev.gone) throw MessagingException("NOT_FOUND", "Notification dismiss ho chuki hai — reply nahi ho sakti")
            if (ev.replyAction == null) {
                throw MessagingException("REPLY_UNSUPPORTED", "Is notification mein inline reply nahi hai")
            }
            if (drafts.size >= MAX_DRAFTS) drafts.remove(drafts.keys.first())
            val id = "draft_" + java.util.UUID.randomUUID().toString().replace("-", "").take(16)
            drafts[id] = Draft(id, eventId, text, now)
            return mapOf(
                "draft_id" to id,
                "event_id" to eventId,
                "package" to ev.pkg,
                "app" to SUPPORTED_PACKAGES[ev.pkg],
                "to" to ev.sender,
                "text" to text,
                "expires_in_seconds" to DRAFT_TTL_MS / 1000,
            )
        }
    }

    fun sendReply(context: Context, draftId: String, now: Long = System.currentTimeMillis()): Map<String, Any?> {
        val ev: Event
        val draft: Draft
        synchronized(lock) {
            pruneDrafts(now)
            draft = drafts[draftId]
                ?: throw MessagingException("NOT_FOUND", "Draft nahi mila ya expire ho gaya — dobara prepare karein")
            ev = events[draft.eventId]
                ?: throw MessagingException("NOT_FOUND", "Event nahi mila ya expire ho gaya")
            if (!ev.canReply) throw MessagingException("NOT_FOUND", "Notification dismiss ho chuki hai — reply nahi ho sakti")
            while (replyTimes.isNotEmpty() && now - replyTimes.first() > 60_000L) replyTimes.removeFirst()
            if (replyTimes.size >= MAX_REPLIES_PER_MIN) {
                throw MessagingException("RATE_LIMITED", "Bahut zyada replies — 1 minute baad try karein")
            }
            drafts.remove(draftId) // single-use: send fail ho to bhi dobara nahi
            replyTimes.addLast(now)
        }
        val action = ev.replyAction!!
        val input = ev.remoteInput!!
        try {
            val intent = Intent()
            val results = Bundle().apply { putCharSequence(input.resultKey, draft.text) }
            RemoteInput.addResultsToIntent(arrayOf(input), intent, results)
            action.actionIntent.send(context, 0, intent)
        } catch (e: PendingIntent.CanceledException) {
            throw MessagingException("SEND_FAILED", "App ne reply action cancel kar diya")
        }
        return mapOf(
            "sent" to true,
            "delivery" to "handed_to_app", // delivery confirm nahi hoti
            "event_id" to ev.id,
            "package" to ev.pkg,
        )
    }

    private fun pruneDrafts(now: Long) {
        drafts.entries.removeAll { now - it.value.createdAtMs > DRAFT_TTL_MS }
    }

    /** Sirf tests/diagnostics ke liye. */
    fun resetForTest() = synchronized(lock) {
        events.clear(); drafts.clear(); replyTimes.clear()
    }
}
