package com.deviceagent.app

import android.content.Context

/**
 * User-controlled (sirf is device ke UI se) per-app notification filter.
 * Blocked package ki notifications na buffer hoti hain, na API se milti hain.
 * Remote API se is filter ko badalne ka koi route nahi (privilege-escalation
 * se bachne ke liye) — sirf local `device_agent/notifications` channel.
 */
object NotificationFilter {
    private const val PREFS = "notification_filter"
    private const val KEY = "blocked_packages"
    @Volatile private var cache: Set<String>? = null

    fun blocked(context: Context): Set<String> {
        cache?.let { return it }
        val s: Set<String> = try {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getStringSet(KEY, emptySet())?.toSet() ?: emptySet()
        } catch (_: Exception) { emptySet() }
        cache = s
        return s
    }

    fun setBlocked(context: Context, packages: Set<String>) {
        val copy = packages.toSet()
        cache = copy
        try {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putStringSet(KEY, copy).apply()
        } catch (_: Exception) {}
        // Pehle se buffer mein padi notifications/messaging events bhi hata do.
        DeviceNotificationListener.purge(copy)
        MessagingStore.purgePackages(copy)
    }

    fun allows(context: Context, pkg: String?): Boolean =
        pkg == null || pkg !in blocked(context)

    fun <T : Map<String, *>> filter(context: Context, list: List<T>): List<T> =
        list.filter { allows(context, it["package"] as? String) }
}
