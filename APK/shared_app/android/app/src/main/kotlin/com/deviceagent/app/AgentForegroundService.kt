package com.deviceagent.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Item 85: agent ko Android background mein zinda rakhne wali foreground
 * service. Yeh sirf **process ko high-priority par rakhti hai** (aur
 * partial wake lock se CPU network ke liye jaagta rehta hai) — asli agent
 * Dart isolate mein hi chalta hai. Isliye MainActivity back-press par task
 * ko background mein bhejti hai (finish nahi karti), taaki Flutter engine
 * (aur uska WebSocket) zinda rahe.
 *
 * Limits (honest): user app ko recents se swipe kare ya OS force-stop kare
 * to agent band ho jata hai; Android 15+ par bhi system aggressive OEM
 * battery managers (Xiaomi/Huawei...) ko user se "unrestricted battery"
 * dilwana padta hai (Permission Center mein item hai).
 */
class AgentForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "agent_background_channel"
        private const val NOTIFICATION_ID = 1002
        @Volatile var running = false
            private set

        /**
         * Item 85 (honest status): Flutter engine (jisme asli agent chalta
         * hai) abhi attached/zinda hai ya nahi. Service process zinda rakhti
         * hai, lekin Activity destroy (recents se swipe) hone par engine bhi
         * mar jata hai — tab notification ko "connected" nahi kehna chahiye.
         * Headless engine (ANDROID_HEADLESS_DESIGN.md) aane tak yahi sach hai.
         */
        /** Koi bhi engine (UI ya headless) agent chala raha hai? */
        val engineAttached: Boolean get() = AgentRuntime.agentRunning

        const val ACTION_HEADLESS = "com.deviceagent.app.action.HEADLESS"

        /**
         * Activity band hone par headless engine shuru karo.
         *
         * Pehle yahan `startForegroundService(ACTION_HEADLESS)` hota tha — lekin
         * Activity.onDestroy (swipe-away) ke waqt app background mein hoti hai
         * aur Android 12+ background se foreground service start karna
         * `ForegroundServiceStartNotAllowedException` deta hai (exception
         * chup-chaap nigal li jati thi => headless kabhi shuru nahi hota tha).
         * Service pehle se foreground mein chal rahi hai (process isi se
         * zinda hai), isliye same-process object ko seedha call karte hain —
         * koi nayi service start request nahi.
         */
        fun requestHeadless(context: android.content.Context) {
            if (!running) return
            if (AgentRuntime.uiEngineAttached) return
            AgentRuntime.agentModeEnabled = true
            HeadlessAgent.start(context.applicationContext)
        }

        private fun ensureChannel(context: android.content.Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID, "Agent running", NotificationManager.IMPORTANCE_LOW
                )
                context.getSystemService(NotificationManager::class.java)
                    .createNotificationChannel(channel)
            }
        }

        fun buildNotification(context: android.content.Context): Notification {
            ensureChannel(context)
            val open = android.app.PendingIntent.getActivity(
                context, 0, Intent(context, MainActivity::class.java),
                android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
            )
            // Honest wording: yeh sirf *engine/process* ka haal batata hai, server
            // se connection ka nahi (offline hone par bhi engine chalta rehta hai).
            val text = if (AgentRuntime.uiEngineAttached) {
                "Agent is running (app open)"
            } else if (AgentRuntime.headlessRunning) {
                "Agent running in background mode — open the app for screen capture or permission prompts"
            } else {
                "Agent is NOT running — app was closed. Tap to reopen and reconnect."
            }
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setContentTitle("Device Agent")
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setSmallIcon(android.R.drawable.ic_menu_manage)
                .setOngoing(true)
                .setContentIntent(open)
                .build()
        }

        /** Chalti service ki notification ko current engine state se sync karo. */
        fun refreshNotification(context: android.content.Context) {
            if (!running) return
            try {
                context.getSystemService(NotificationManager::class.java)
                    .notify(NOTIFICATION_ID, buildNotification(context))
            } catch (_: Exception) {
                // Notification update best-effort hai; service par asar nahi.
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification(this)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        if (wakeLock == null) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DeviceAgent:agent").apply {
                setReferenceCounted(false)
                acquire() // service band hone par release (onDestroy)
            }
        }
        running = true

        // Item 85 (headless): UI engine na ho (Activity band, ya process
        // kill ke baad sticky restart) aur agent mode ON ho => headless engine.
        val headlessRequested = intent?.action == ACTION_HEADLESS
        val stickyRestart = intent == null && AgentRuntime.loadAgentMode(this)
        if ((headlessRequested || stickyRestart) && !AgentRuntime.uiEngineAttached) {
            AgentRuntime.agentModeEnabled = true
            HeadlessAgent.start(applicationContext)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        HeadlessAgent.stop(applicationContext)
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
