package com.deviceagent.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of `ChannelNames.screenCapture` (MethodChannel) and
 * `ChannelNames.screenLiveStream` (EventChannel) from
 * platform_channel_bridge.dart — matches `ScreenCaptureBridge` in Dart.
 *
 * Flow:
 *  1. Dart calls "requestPermission" → MainActivity shows the mandatory
 *     Android system consent dialog (cannot be bypassed — Section 6.6
 *     item 2).
 *  2. On approval, MainActivity starts ScreenCaptureService with the
 *     granted resultCode/Intent.
 *  3. "captureScreenshot" → one-shot PNG, base64-encoded.
 *  4. EventChannel onListen → continuous JPEG frames for "Watch Live"
 *     (Section 2.1).
 */
class ScreenCaptureHandler(private val activity: HandlerHost) {

    private var pendingPermissionResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    /** `device_agent/audio_stream` — system audio PCM chunks (16kHz/mono/16-bit). */
    private fun registerAudio(messenger: BinaryMessenger) {
        EventChannel(messenger, "device_agent/audio_stream").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    val service = activity.currentScreenCaptureService()
                    if (service == null) {
                        events.error("PERMISSION_REQUIRED", "Screen capture session active nahi hai.", null)
                        events.endOfStream()
                        return
                    }
                    val started = service.startAudioStreaming(
                        onChunk = { chunk -> mainHandler.post { events.success(chunk) } },
                        onError = { msg ->
                            mainHandler.post {
                                events.error(
                                    if (msg.startsWith("AUDIO_UNSUPPORTED")) "CAPABILITY_UNAVAILABLE" else "STREAM_FAILED",
                                    msg, null,
                                )
                            }
                        },
                    )
                    if (!started) events.endOfStream()
                }

                override fun onCancel(arguments: Any?) {
                    activity.currentScreenCaptureService()?.stopAudioStreaming()
                }
            }
        )
    }

    fun register(flutterEngine: FlutterEngine) {
        registerAudio(flutterEngine.dartExecutor.binaryMessenger)
        val methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ChannelNames.screenCapture
        )
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> requestPermission(result)
                "captureScreenshot" -> captureScreenshot(result)
                // Website click -> device pixel mapping ke liye asli screen size.
                "getScreenSize" -> {
                    val wm = activity.applicationContext
                        .getSystemService(Context.WINDOW_SERVICE) as WindowManager
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val b = wm.currentWindowMetrics.bounds
                        result.success(mapOf("width" to b.width(), "height" to b.height()))
                    } else {
                        val m = DisplayMetrics()
                        @Suppress("DEPRECATION")
                        wm.defaultDisplay.getRealMetrics(m)
                        result.success(mapOf("width" to m.widthPixels, "height" to m.heightPixels))
                    }
                }
                "stopStream" -> {
                    activity.currentScreenCaptureService()?.stopStreaming()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        val eventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ChannelNames.screenLiveStream
        )
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val service = activity.currentScreenCaptureService()
                if (service == null) {
                    // Pehle yahan chup-chaap kuch nahi hota tha — Dart ko
                    // "started" mil jata aur frames kabhi nahi aate.
                    events.error(
                        "PERMISSION_REQUIRED",
                        "Screen capture session active nahi hai — pehle screen capture consent do.",
                        null
                    )
                    events.endOfStream()
                    return
                }
                val args = arguments as? Map<*, *>
                service.startStreaming(
                    fps = (args?.get("fps") as? Number)?.toInt() ?: 20,
                    maxWidth = (args?.get("max_width") as? Number)?.toInt() ?: 1080,
                    jpegQuality = (args?.get("quality") as? Number)?.toInt() ?: 70,
                ) { frameBytes ->
                    // Stage 9: raw JPEG bytes seedha Dart ko (Uint8List) — pehle base64
                    // (+33% size, extra CPU) hota tha. Windows/Linux abhi String bhejte hain;
                    // Dart dono handle karta hai.
                    activity.runOnUiThread { events.success(frameBytes) }
                }
            }

            override fun onCancel(arguments: Any?) {
                activity.currentScreenCaptureService()?.stopStreaming()
            }
        })
    }

    /** Item 85: engine destroy par live stream band (dead sink par frames na jaayein). */
    fun dispose() {
        try { activity.currentScreenCaptureService()?.stopStreaming() } catch (_: Exception) {}
        pendingPermissionResult = null
    }

    /** Android 13+: foreground notification dikhane ke liye runtime permission. */
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(
                activity, Manifest.permission.POST_NOTIFICATIONS
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                activity.requireUi("permission dialog"),
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                MainActivity.REQUEST_CODE_NOTIFICATIONS_PERMISSION
            )
        }
    }

    /**
     * `AudioPlaybackCaptureConfiguration` ko RECORD_AUDIO permission chahiye hoti
     * hai (mic access nahi, sirf API ki requirement) — screen consent ke saath
     * best-effort maang lete hain taaki audio feature baad mein kaam kare.
     */
    private fun ensureAudioPermission() {
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                activity.requireUi("permission dialog"),
                arrayOf(Manifest.permission.RECORD_AUDIO),
                MainActivity.REQUEST_CODE_AUDIO_PERMISSION
            )
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        // Item 74: pehle ki pending request overwrite ho kar hamesha ke
        // liye latak jati thi — ab usse false se complete karte hain.
        activity.requireUi("screen capture consent") // headless => NEEDS_UI (pending se pehle)
        pendingPermissionResult?.success(false)
        pendingPermissionResult = result
        ensureNotificationPermission()
        ensureAudioPermission() // system-audio streaming ke liye (best-effort; na mile to sirf audio feature kaam nahi karega)
        val manager = activity.getSystemService(
            android.content.Context.MEDIA_PROJECTION_SERVICE
        ) as MediaProjectionManager
        activity.startActivityForResult(
            manager.createScreenCaptureIntent(),
            MainActivity.REQUEST_CODE_SCREEN_CAPTURE
        )
    }

    fun onPermissionResult(resultCode: Int, data: Intent?) {
        val pending = pendingPermissionResult
        pendingPermissionResult = null
        val granted = resultCode == Activity.RESULT_OK && data != null
        if (!granted) {
            pending?.success(false)
            return
        }

        // Item 74: Dart ko "granted" tab batate hain jab service ne
        // MediaProjection + VirtualDisplay sach mein bana liya — pehle
        // result turant chala jata tha aur agla captureScreenshot
        // `NOT_READY` se fail hota tha (race).
        var delivered = false
        fun deliver(ok: Boolean) {
            if (delivered) return
            delivered = true
            pending?.success(ok)
        }
        ScreenCaptureService.onSessionReady = { ok -> mainHandler.post { deliver(ok) } }
        mainHandler.postDelayed({
            if (!delivered) {
                ScreenCaptureService.onSessionReady = null
                deliver(false)
            }
        }, 8000)

        val serviceIntent = Intent(activity, ScreenCaptureService::class.java).apply {
            putExtra(ScreenCaptureService.EXTRA_RESULT_CODE, resultCode)
            putExtra(ScreenCaptureService.EXTRA_RESULT_DATA, data)
        }
        activity.startForegroundService(serviceIntent)
    }

    private fun captureScreenshot(result: MethodChannel.Result) {
        val service = activity.currentScreenCaptureService()
        if (service == null) {
            result.error("NOT_READY", "Screen capture session active nahi hai", null)
            return
        }
        // Item 63: PNG compress bhaari hai — main thread par ANR risk.
        Thread {
            val encoded = try {
                service.captureLatestFrameAsPng()?.let { Base64.encodeToString(it, Base64.NO_WRAP) }
            } catch (e: Exception) {
                null
            }
            activity.runOnUiThread {
                if (encoded == null) {
                    result.error("NOT_READY", "Abhi tak koi frame nahi mila — thodi der baad try karein", null)
                } else {
                    result.success(encoded)
                }
            }
        }.start()
    }
}
