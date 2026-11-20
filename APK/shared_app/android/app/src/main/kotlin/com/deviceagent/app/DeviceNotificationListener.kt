package com.deviceagent.app

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Item 84 (P1-06): Android `NotificationListenerService`.
 *
 * Privacy/safety design:
 *  - Notifications **sirf memory mein** (ring buffer, max [MAX_ITEMS]) —
 *    disk par kabhi save nahi hote.
 *  - Sirf metadata + title/text; icons/large images/actions nahi.
 *  - Is app ki apni notifications ignore (screen-share foreground
 *    notification wagairah).
 *  - Ongoing (media player, foreground services) skip.
 *  - Access tabhi milta hai jab user ne Settings > Notification access mein
 *    khud enable kiya ho — `NotificationsHandler.isEnabled()`.
 */
class DeviceNotificationListener : NotificationListenerService() {

    companion object {
        const val MAX_ITEMS = 100
        private const val MAX_TEXT = 500

        private val lock = Any()
        private val buffer = ArrayDeque<Map<String, Any?>>()

        /** Naye se purane order mein, `since` (epoch ms) ke baad ke, max `limit`. */
        fun recent(limit: Int, sinceMs: Long): List<Map<String, Any?>> = synchronized(lock) {
            buffer.asReversed()
                .filter { (it["posted_at_ms"] as Long) > sinceMs }
                .take(limit.coerceIn(1, MAX_ITEMS))
        }

        fun clear() = synchronized(lock) { buffer.clear() }

        /** User ne app block kiya — buffered notifications turant hatao. */
        fun purge(blocked: Set<String>) = synchronized(lock) {
            buffer.removeAll { (it["package"] as? String) in blocked }
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val n = sbn ?: return
        if (n.packageName == packageName) return
        if (n.isOngoing) return
        // Privacy: app ne notification ko VISIBILITY_SECRET mark kiya (banking,
        // OTP, hidden-content) => na recent buffer mein, na messaging store mein.
        if (n.notification.visibility == Notification.VISIBILITY_SECRET) return
        if (!NotificationFilter.allows(this, n.packageName)) return
        // P1-06: supported messaging apps ke events + inline-reply handle.
        try { MessagingStore.onPosted(n) } catch (_: Exception) {}
        val extras = n.notification.extras
        val title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val text = extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()
        val item = mapOf(
            "key" to n.key,
            "package" to n.packageName,
            "title" to title?.take(MAX_TEXT),
            "text" to text?.take(MAX_TEXT),
            "category" to n.notification.category,
            "posted_at_ms" to n.postTime,
        )
        synchronized(lock) {
            // Same key update ho to purani entry hata do.
            buffer.removeAll { it["key"] == n.key }
            buffer.addLast(item)
            while (buffer.size > MAX_ITEMS) buffer.removeFirst()
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        // Buffer "recent events" hai — removal par entry rakhte hain.
        // Messaging reply handle ab invalid hai.
        sbn?.let { MessagingStore.onRemoved(it.key) }
    }

    override fun onListenerDisconnected() {
        MessagingStore.clear()
        super.onListenerDisconnected()
        // OEM/OS listener ko unbind kar de to access ON hone ke bawajood events
        // band ho jate the — dobara bind maango (API 24+; minSdk 26).
        try {
            requestRebind(android.content.ComponentName(this, DeviceNotificationListener::class.java))
        } catch (_: Exception) {
        }
    }
}
