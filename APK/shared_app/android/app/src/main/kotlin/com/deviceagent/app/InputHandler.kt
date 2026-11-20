package com.deviceagent.app

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of `ChannelNames.input` — matches Dart's `InputBridge`
 * (tap/swipe/typeText). Delegate karta hai `InputAccessibilityService`
 * ko, jo tab hi kaam karega jab user ne use Settings mein enable kiya ho.
 */
class InputHandler(private val activity: HandlerHost) {

    fun register(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ChannelNames.input
        )
        channel.setMethodCallHandler { call, result ->
            val service = InputAccessibilityService.instance
            if (service == null) {
                if (call.method == "isEnabled") {
                    result.success(false)
                } else {
                    result.error(
                        "SERVICE_DISABLED",
                        "Accessibility service enable nahi hai. User ko " +
                            "Settings > Accessibility mein isko on karna hoga.",
                        null
                    )
                }
                return@setMethodCallHandler
            }

            when (call.method) {
                "isEnabled" -> result.success(true)
                "tap" -> {
                    val x = (call.argument<Double>("x") ?: 0.0).toFloat()
                    val y = (call.argument<Double>("y") ?: 0.0).toFloat()
                    service.tap(x, y) { success -> result.success(success) }
                }
                "swipe" -> {
                    val x1 = (call.argument<Double>("x1") ?: 0.0).toFloat()
                    val y1 = (call.argument<Double>("y1") ?: 0.0).toFloat()
                    val x2 = (call.argument<Double>("x2") ?: 0.0).toFloat()
                    val y2 = (call.argument<Double>("y2") ?: 0.0).toFloat()
                    val duration = (call.argument<Int>("duration_ms") ?: 200).toLong()
                    service.swipe(x1, y1, x2, y2, duration) { success ->
                        result.success(success)
                    }
                }
                "pressKey" -> result.success(service.pressKey(call.argument<String>("key") ?: ""))
                "typeText" -> {
                    val text = call.argument<String>("text") ?: ""
                    val append = call.argument<Boolean>("append") ?: false
                    result.success(service.typeText(text, append))
                }
                "openAccessibilitySettings" -> {
                    activity.startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
