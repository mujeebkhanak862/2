package com.deviceagent.app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Flutter entry point. Section 6.7: "sab channels register karta hai".
 *
 * Har naya capability isi file mein ek line add karega, apne handler ko
 * configureFlutterEngine() ke andar register karke — is se
 * `platform_channel_bridge.dart` ke ChannelNames se match hota hai.
 *
 * Screen Capture ke liye ek extra zimmedari bhi hai: MediaProjection
 * consent sirf ek Activity hi maang sakti hai (Section 6.6 item 2 —
 * mandatory system dialog, bypass nahi ho sakta), isliye
 * onActivityResult() yahan handle hota hai aur result
 * ScreenCaptureHandler ko forward hota hai.
 */
class MainActivity : FlutterActivity() {

    /**
     * Item 85: agent mode ON ho (foreground service chal rahi ho) to
     * back-press app ko **finish nahi karta**, sirf background mein bhejta
     * hai. (Ab state process-wide `AgentRuntime` mein hai — headless
     * engine bhi yahi padhta hai.)
     */
    var agentModeEnabled: Boolean
        get() = AgentRuntime.agentModeEnabled
        set(value) = AgentRuntime.persistAgentMode(this, value)

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (agentModeEnabled) {
            moveTaskToBack(true)
        } else {
            @Suppress("DEPRECATION")
            super.onBackPressed()
        }
    }

    companion object {
        const val REQUEST_CODE_SCREEN_CAPTURE = 4242
        const val REQUEST_CODE_PICK_DIRECTORY = 4243
        const val REQUEST_CODE_LOCATION_PERMISSION = 4244
        const val REQUEST_CODE_CONTACTS_PERMISSION = 4245
        const val REQUEST_CODE_NOTIFICATIONS_PERMISSION = 4246
        const val REQUEST_CODE_AUDIO_PERMISSION = 4247
    }

    private lateinit var registrar: ChannelRegistrar

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // Item 85: UI engine agent ka maalik banne wala hai — headless
        // engine (agar chal raha) pehle band, taaki do connections na hon.
        HeadlessAgent.stopNow(applicationContext)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Item 85: UI engine (aur uska agent) ab zinda hai.
        AgentRuntime.uiEngineAttached = true
        AgentForegroundService.refreshNotification(applicationContext)

        registrar = ChannelRegistrar(HandlerHost(this, this))
        registrar.registerAll(flutterEngine)
    }

    override fun onDestroy() {
        // Rotation/config-change par naya engine turant attach hoga; asli
        // close (swipe-away / finish) par UI engine mar gaya.
        if (!isChangingConfigurations) {
            AgentRuntime.uiEngineAttached = false
            if (AgentRuntime.agentModeEnabled) {
                // Agent mode ON: service headless engine mein agent jaari rakhe.
                AgentForegroundService.requestHeadless(applicationContext)
            }
            AgentForegroundService.refreshNotification(applicationContext)
        }
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQUEST_CODE_SCREEN_CAPTURE -> registrar.screenCapture.onPermissionResult(resultCode, data)
            REQUEST_CODE_PICK_DIRECTORY -> registrar.files.onDirectoryPicked(resultCode, data)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            REQUEST_CODE_LOCATION_PERMISSION -> registrar.locationNetwork.onPermissionResult(grantResults)
            REQUEST_CODE_CONTACTS_PERMISSION -> registrar.contacts.onPermissionResult(grantResults)
        }
    }

    /** Purane callers ke liye (ab `HandlerHost.currentScreenCaptureService()` use hota hai). */
    fun currentScreenCaptureService(): ScreenCaptureService? = ScreenCaptureService.instance
}
