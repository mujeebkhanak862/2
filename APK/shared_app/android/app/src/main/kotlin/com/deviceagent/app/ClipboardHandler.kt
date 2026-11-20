package com.deviceagent.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of `ChannelNames.clipboard` — matches Dart's
 * `ClipboardBridge`.
 *
 * **Important Android limitation:** Android 10 (API 29) se background
 * apps clipboard read nahi kar saktay — sirf currently-focused app.
 * Isliye `readText` un cases mein `null` return karega jab agent app
 * foreground mein na ho. Yeh Android ka privacy control hai, isko
 * bypass karne ki koshish nahi ki gayi (Section 6.6 jaisi hi philosophy —
 * OS-level protections ko respect karna).
 */
class ClipboardHandler(private val activity: HandlerHost) {

    fun register(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ChannelNames.clipboard
        )
        channel.setMethodCallHandler { call, result ->
            val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            when (call.method) {
                "readText" -> {
                    // Item 68: Android 10+ par app foreground mein na ho to
                    // `primaryClip` chup-chaap null deta hai — "clipboard
                    // khaali hai" aur "access nahi mila" alag cheezein
                    // hain, isliye background mein saaf error.
                    if (!activity.hasWindowFocus()) {
                        result.error(
                            "CLIPBOARD_UNAVAILABLE",
                            "Android 10+ par clipboard sirf tab padha ja sakta hai jab app foreground mein ho",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    val clip = clipboard.primaryClip
                    if (clip != null && clip.itemCount > 0) {
                        result.success(clip.getItemAt(0).text?.toString())
                    } else {
                        result.success(null)
                    }
                }
                "writeText" -> {
                    val text = call.argument<String>("text") ?: ""
                    clipboard.setPrimaryClip(ClipData.newPlainText("device_agent", text))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
