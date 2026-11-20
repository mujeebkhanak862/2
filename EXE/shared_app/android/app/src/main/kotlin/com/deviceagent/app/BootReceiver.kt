package com.deviceagent.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Reboot / app-update ke baad agent mode wapas shuru karta hai.
 *
 * Sirf tab jab user ne pehle "background mein chalao" (agent mode) ON kiya tha
 * ([AgentRuntime.loadAgentMode]) — warna kuch nahi hota. Foreground service
 * `ACTION_HEADLESS` ke saath start hoti hai, to UI ke bina headless engine chalta
 * hai. (Android 15: BOOT_COMPLETED se `specialUse` type allowed hai; mediaProjection
 * jaise types nahi — woh yahan start hi nahi hote.)
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) return
        if (!AgentRuntime.loadAgentMode(context)) return
        try {
            context.startForegroundService(
                Intent(context, AgentForegroundService::class.java)
                    .setAction(AgentForegroundService.ACTION_HEADLESS)
            )
        } catch (_: Exception) {
            // OEM/OS ne background start roka — user app khol kar chala sakta hai.
        }
    }
}
