package com.deviceagent.app

import android.content.Context

/**
 * Item 85 (headless): process-wide agent state — Activity/Service dono
 * yahin se padhte-likhte hain (pehle `MainActivity` ke fields mein tha).
 *
 * Do alag engines mein se **sirf ek** agent chalata hai:
 *  - UI engine ([uiEngineAttached]) — jab Activity zinda ho.
 *  - Headless engine ([headlessRunning], `HeadlessAgent.kt`) — Activity
 *    destroy hone ke baad, foreground service ke andar.
 */
object AgentRuntime {
    private const val PREFS = "agent_runtime"
    private const val KEY_AGENT_MODE = "agent_mode"

    /** Foreground service on (user ne "background mein chalao" kiya). */
    @Volatile var agentModeEnabled: Boolean = false
    @Volatile var uiEngineAttached: Boolean = false
    @Volatile var headlessRunning: Boolean = false

    /** Koi bhi engine agent chala raha hai? (notification ka sach.) */
    val agentRunning: Boolean get() = uiEngineAttached || headlessRunning

    /** Process-kill ke baad (sticky restart) headless dobara shuru karne ke liye. */
    fun persistAgentMode(context: Context, enabled: Boolean) {
        agentModeEnabled = enabled
        try {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_AGENT_MODE, enabled).apply()
        } catch (_: Exception) {}
    }

    fun loadAgentMode(context: Context): Boolean = try {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_AGENT_MODE, false)
    } catch (_: Exception) { false }
}
