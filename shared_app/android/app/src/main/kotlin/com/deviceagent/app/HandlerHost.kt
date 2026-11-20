package com.deviceagent.app

import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.Handler
import android.os.Looper

/** UI-only operation (dialog/permission/consent) headless mode mein possible nahi. */
class NeedsUiException(what: String) :
    RuntimeException("NEEDS_UI: $what ke liye app (Activity) kholni padegi")

/**
 * Item 85 (headless): channel handlers ka host.
 *
 * Pehle har handler seedha `MainActivity` leta tha, isliye Activity ke
 * bina (headless engine) koi bhi handler nahi ban sakta tha. `HandlerHost`
 * ek [ContextWrapper] hai — `activity` ki jagah `Context` maangne wali har
 * API (ContextCompat, Intent(...), DocumentFile...) seedha kaam karti hai —
 * aur Activity-only cheezein (`runOnUiThread`, `startActivityForResult`,
 * permission dialogs) yahin safe tareeqe se handle hoti hain:
 *  - UI engine: `ui` = MainActivity, sab pehle jaisa.
 *  - Headless engine: `ui` = null; UI-only cheezein [NeedsUiException]
 *    (Flutter ko error `NEEDS_UI`), baaki sab (location, status, apps,
 *    notifications, messaging, files-on-granted-tree, input via
 *    Accessibility...) normal chalta hai.
 */
class HandlerHost(base: Context, private val ui: MainActivity?) : ContextWrapper(base) {

    val hasUi: Boolean get() = ui != null

    /** Activity chahiye wale calls ke liye (permission dialog etc.). */
    fun requireUi(what: String = "yeh action"): MainActivity =
        ui ?: throw NeedsUiException(what)

    fun runOnUiThread(action: Runnable) {
        val a = ui
        if (a != null) a.runOnUiThread(action) else Handler(Looper.getMainLooper()).post(action)
    }

    fun hasWindowFocus(): Boolean = ui?.hasWindowFocus() ?: false

    @Suppress("DEPRECATION")
    fun startActivityForResult(intent: Intent, requestCode: Int) {
        requireUi("system dialog").startActivityForResult(intent, requestCode)
    }

    fun currentScreenCaptureService(): ScreenCaptureService? = ScreenCaptureService.instance

    var agentModeEnabled: Boolean
        get() = AgentRuntime.agentModeEnabled
        set(value) = AgentRuntime.persistAgentMode(this, value)

    /** Service/Application context se Activity start karne ke liye NEW_TASK zaroori. */
    override fun startActivity(intent: Intent) {
        if (ui == null) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        super.startActivity(intent)
    }
}
