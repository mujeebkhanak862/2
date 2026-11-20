package com.deviceagent.app

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.PowerManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Audit fix (P1-05, Section 13 #6): "Real lock-state detection — No
 * KeyguardManager integration found." Pehle server ko sirf ek connect-
 * time optimistic guess milta tha (`ONLINE_UNLOCKED`), kyunki koi native
 * bridge nahi tha jo Android se asal state poochta. Yeh file woh bridge
 * hai.
 *
 * Do cheezein deta hai:
 *  - `currentState()` (MethodChannel) — one-shot query, [computeState].
 *  - Continuous push (EventChannel) — [BroadcastReceiver] jo
 *    `ACTION_SCREEN_ON`/`ACTION_SCREEN_OFF`/`ACTION_USER_PRESENT` sunta
 *    hai (yeh teeno hi sirf tab fire hote hain jab actual state badle —
 *    koi polling loop nahi, battery-friendly).
 *
 * **State mapping (server ke fixed 6-state vocabulary se):**
 *  - `!powerManager.isInteractive` (screen off/dozing) -> `SCREEN_OFF`
 *  - `isInteractive && keyguardManager.isKeyguardLocked` -> `ONLINE_LOCKED`
 *  - warna -> `ONLINE_UNLOCKED`
 *
 * **Honest gap**: `SLEEPING` (deep Doze/App Standby) is mapping mein kabhi
 * report nahi hota — Android ka public API is granularity mein Doze ko
 * "screen off" se reliably alag nahi karta bina extra permissions
 * (`ACCESS_NETWORK_STATE` + `PowerManager.isDeviceIdleMode`, jo khud bhi
 * approximate hai). `SCREEN_OFF` already command-dispatch ko sahi tarah
 * gate karta hai (device state gate dono ko "background-only" treat karta
 * hai), isliye yeh koi functional gap nahi — sirf granularity ka farak
 * hai jo yahan explicitly likha hua hai, chhupaya nahi gaya.
 */
class LockStateHandler(private val context: Context) {

    private var eventSink: EventChannel.EventSink? = null

    private val keyguardManager: KeyguardManager
        get() = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager

    private val powerManager: PowerManager
        get() = context.getSystemService(Context.POWER_SERVICE) as PowerManager

    private fun computeState(): String {
        if (!powerManager.isInteractive) return "SCREEN_OFF"
        return if (keyguardManager.isKeyguardLocked) "ONLINE_LOCKED" else "ONLINE_UNLOCKED"
    }

    private val screenStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            // Har teeno action ke baad hi state dobara compute karke bhejte
            // hain — is se caller (Dart side) hamesha fresh, authoritative
            // value paata hai chahe trigger kuch bhi ho (screen off, screen
            // on lekin abhi bhi locked, ya unlock/USER_PRESENT).
            // Item 71: ACTION_SCREEN_OFF ke waqt `powerManager.isInteractive`
            // abhi bhi stale `true` ho sakta hai (broadcast aur state update
            // ke beech race) — isliye state intent ke action se nikalte hain.
            val state = when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> "SCREEN_OFF"
                Intent.ACTION_USER_PRESENT -> "ONLINE_UNLOCKED"
                Intent.ACTION_SCREEN_ON ->
                    if (keyguardManager.isKeyguardLocked) "ONLINE_LOCKED" else "ONLINE_UNLOCKED"
                else -> computeState()
            }
            eventSink?.success(state)
        }
    }

    private var isReceiverRegistered = false

    private fun registerReceiver() {
        if (isReceiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT) // keyguard hati (unlock ho gaya)
        }
        context.registerReceiver(screenStateReceiver, filter)
        isReceiverRegistered = true
    }

    /** Item 85: engine destroy par receiver/sink saaf (headless create/destroy leak na kare). */
    fun dispose() {
        unregisterReceiver()
        eventSink = null
    }

    private fun unregisterReceiver() {
        if (!isReceiverRegistered) return
        try {
            context.unregisterReceiver(screenStateReceiver)
        } catch (_: IllegalArgumentException) {
            // Already unregistered — safe to ignore.
        }
        isReceiverRegistered = false
    }

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, ChannelNames.lockState
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "currentState" -> result.success(computeState())
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger, ChannelNames.lockStateEvents
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
                registerReceiver()
                // Listener attach hote hi turant ek current value bhi bhej
                // dete hain — taaki Dart side ko pehla event ke liye
                // interactive change ka wait na karna pade.
                sink.success(computeState())
            }

            override fun onCancel(arguments: Any?) {
                unregisterReceiver()
                eventSink = null
            }
        })
    }
}
