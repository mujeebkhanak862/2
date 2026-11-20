package com.deviceagent.app

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of `ChannelNames.browser` — matches Dart's `BrowserBridge`
 * Android-only methods. Windows/Linux use `CdpClient` (Chrome DevTools
 * Protocol) instead; Android has no equivalent without root/adb, so this
 * uses `InputAccessibilityService`'s semantic-tree methods, which control
 * whatever browser (or any app) is currently open — using its real,
 * already-logged-in session.
 */
class BrowserHandler(private val activity: HandlerHost) {

    fun register(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ChannelNames.browser
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "openUrl" -> openUrl(call.argument("url") ?: "", result)
                "findAndClick" -> withService(result) {
                    result.success(it.findAndClick(call.argument("text") ?: ""))
                }
                "findAndType" -> withService(result) {
                    result.success(
                        it.findAndType(
                            call.argument("fieldLabel") ?: "",
                            call.argument("text") ?: ""
                        )
                    )
                }
                "getVisibleText" -> withService(result) {
                    result.success(it.getVisibleText())
                }
                "launchDesktopBrowser" ->
                    // Windows/Linux-only concept — Android par no-op
                    // (browser hamesha "already available" hai via openUrl).
                    result.success(true)
                else -> result.notImplemented()
            }
        }
    }

    private fun withService(
        result: MethodChannel.Result,
        block: (InputAccessibilityService) -> Unit
    ) {
        val service = InputAccessibilityService.instance
        if (service == null) {
            result.error(
                "SERVICE_DISABLED",
                "Accessibility service enable nahi hai. User ko Settings > " +
                    "Accessibility mein isko on karna hoga.",
                null
            )
        } else {
            block(service)
        }
    }

    /** Kisi bhi default/system browser mein URL kholta hai. */
    private fun openUrl(url: String, result: MethodChannel.Result) {
        // Item 13: sirf http/https — `intent:`, `content:`, `file:`, `tel:`
        // jaisi schemes se arbitrary activities launch ho sakti hain.
        val scheme = Uri.parse(url.trim()).scheme?.lowercase()
        if (scheme != "http" && scheme != "https") {
            result.error("INVALID_URL", "Sirf http/https URLs allowed hain", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message, null)
        }
    }
}
