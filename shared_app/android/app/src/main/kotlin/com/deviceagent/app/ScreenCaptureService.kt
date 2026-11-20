package com.deviceagent.app

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ComponentCallbacks
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import java.io.ByteArrayOutputStream

/**
 * Foreground service jo MediaProjection session chalata hai.
 *
 * Stage 5 fixes:
 *  - **Critical**: pehle `resultCode != -1` check tha, lekin
 *    `Activity.RESULT_OK == -1` hai — yani permission milne ke baad bhi
 *    projection kabhi start hi nahi hota tha. Ab `== RESULT_OK`.
 *  - Item 61: Android 14+ par `MediaProjection.registerCallback()` bina
 *    `createVirtualDisplay()` crash/IllegalStateException deta hai. Ab
 *    callback pehle register hota hai; `onStop` (user ne system UI se
 *    sharing band ki) par poora cleanup + service stop.
 *  - Item 62: static screen par `acquireLatestImage()` null deta tha =>
 *    `NOT_READY`. Ab latest frame ek `Image` ke roop mein held rehta hai
 *    (conversion sirf capture par), isliye screenshot hamesha milta hai.
 *  - Item 63: live-stream JPEG compress ab background HandlerThread par,
 *    720px width par downscale, ~8 fps cap, quality 50.
 *  - Item 73: rotation/resolution change par VirtualDisplay resize.
 *  - Item 74: `onSessionReady` callback — handler ab permission ka result
 *    tab deta hai jab session sach mein ready ho (race nahi).
 */
class ScreenCaptureService : Service() {

    companion object {
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"
        private const val NOTIFICATION_CHANNEL_ID = "screen_capture_channel"
        private const val NOTIFICATION_ID = 1001

        // Defaults (Stage 9 smoothness): ~20 fps, 1080px, quality 70. `startStreaming`
        // inhe per-stream override karta hai (website ka fps/quality selector).
        private const val DEFAULT_STREAM_MAX_WIDTH = 1080
        private const val DEFAULT_STREAM_FPS = 20
        private const val DEFAULT_STREAM_JPEG_QUALITY = 70

        var instance: ScreenCaptureService? = null
            private set

        /** Item 74: session ready (true) ya fail (false) hone par ek baar call hota hai. */
        var onSessionReady: ((Boolean) -> Unit)? = null
    }

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var frameThread: HandlerThread? = null
    private var frameHandler: Handler? = null

    @Volatile private var streaming = false
    @Volatile private var released = false
    private var streamCallback: ((ByteArray) -> Unit)? = null
    private var audioManager: AudioCaptureManager? = null
    private var audioCallback: ((ByteArray) -> Unit)? = null
    private var lastStreamAt = 0L
    @Volatile private var streamMinIntervalMs = 1000L / DEFAULT_STREAM_FPS
    @Volatile private var streamMaxWidth = DEFAULT_STREAM_MAX_WIDTH
    @Volatile private var streamJpegQuality = DEFAULT_STREAM_JPEG_QUALITY

    // Item 62: latest raw frame (convert sirf demand par).
    private val heldLock = Any()
    private var heldImage: Image? = null

    private var width = 0
    private var height = 0
    private var density = 0

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            // User ne system UI se sharing band ki ya OS ne projection revoke ki.
            stopAudioStreaming()
            releaseCapture()
            stopSelf()
        }
    }

    /**
     * System audio streaming shuru — isi (screen wali) MediaProjection se.
     * Service khud user-facing error nahi deta; `onError` caller (handler) ko
     * milta hai jo Dart ko PlatformException/EventChannel.error forward karta hai.
     */
    fun startAudioStreaming(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit): Boolean {
        val projection = mediaProjection ?: run { onError("NOT_READY"); return false }
        if (audioManager != null) return true // already running
        val mgr = AudioCaptureManager(projection)
        val ok = mgr.start(onChunk, onError)
        if (ok) { audioManager = mgr; audioCallback = onChunk } else { mgr.stop() }
        return ok
    }

    fun stopAudioStreaming() {
        audioManager?.stop()
        audioManager = null
        audioCallback = null
    }

    private val componentCallbacks = object : ComponentCallbacks {
        override fun onConfigurationChanged(newConfig: Configuration) {
            frameHandler?.post { resizeDisplay() }
        }

        override fun onLowMemory() {}
    }

    private val idleListener = ImageReader.OnImageAvailableListener { reader ->
        val image = try {
            reader.acquireLatestImage()
        } catch (e: IllegalStateException) {
            null
        } ?: return@OnImageAvailableListener
        synchronized(heldLock) {
            heldImage?.close()
            heldImage = image
        }
    }

    private val streamListener = ImageReader.OnImageAvailableListener { reader ->
        val image = try {
            reader.acquireLatestImage()
        } catch (e: IllegalStateException) {
            null
        } ?: return@OnImageAvailableListener
        try {
            val now = SystemClock.elapsedRealtime()
            if (!streaming || now - lastStreamAt < streamMinIntervalMs) return@OnImageAvailableListener
            lastStreamAt = now
            val bitmap = imageToBitmap(image)
            try {
                val scaled = downscale(bitmap)
                try {
                    val out = ByteArrayOutputStream()
                    scaled.compress(Bitmap.CompressFormat.JPEG, streamJpegQuality, out)
                    streamCallback?.invoke(out.toByteArray())
                } finally {
                    if (scaled !== bitmap) scaled.recycle()
                }
            } finally {
                bitmap.recycle()
            }
        } finally {
            image.close()
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()

        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, Int.MIN_VALUE) ?: Int.MIN_VALUE
        @Suppress("DEPRECATION")
        val resultData: Intent? = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            intent?.getParcelableExtra(EXTRA_RESULT_DATA)
        }

        // Critical fix: RESULT_OK == -1, isliye pehle wala `!= -1` check
        // granted case ko hi reject kar deta tha.
        if (resultCode != Activity.RESULT_OK || resultData == null) {
            notifyReady(false)
            stopSelf()
            return START_NOT_STICKY
        }

        val thread = HandlerThread("ScreenCaptureFrames").also { it.start() }
        frameThread = thread
        frameHandler = Handler(thread.looper)

        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val projection = try {
            manager.getMediaProjection(resultCode, resultData)
        } catch (e: Exception) {
            null
        }
        if (projection == null) {
            notifyReady(false)
            stopSelf()
            return START_NOT_STICKY
        }
        mediaProjection = projection
        // Item 61: createVirtualDisplay se PEHLE callback register (Android 14+ requirement).
        projection.registerCallback(projectionCallback, frameHandler)

        val ok = setUpVirtualDisplay()
        if (ok) {
            applicationContext.registerComponentCallbacks(componentCallbacks)
        } else {
            releaseCapture()
            notifyReady(false)
            stopSelf()
            return START_NOT_STICKY
        }
        notifyReady(true)
        return START_NOT_STICKY
    }

    private fun notifyReady(ok: Boolean) {
        val cb = onSessionReady
        onSessionReady = null
        cb?.invoke(ok)
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun currentMetrics(): Triple<Int, Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val dpi = resources.displayMetrics.densityDpi
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = wm.currentWindowMetrics.bounds
            Triple(b.width(), b.height(), dpi)
        } else {
            val m = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(m)
            Triple(m.widthPixels, m.heightPixels, m.densityDpi)
        }
    }

    private fun setUpVirtualDisplay(): Boolean {
        val (w, h, d) = currentMetrics()
        if (w <= 0 || h <= 0) return false
        width = w; height = h; density = d

        // maxImages = 3: 1 held (idle) + 1 in-flight (stream) + 1 spare.
        val reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3)
        imageReader = reader
        reader.setOnImageAvailableListener(idleListener, frameHandler)

        virtualDisplay = mediaProjection?.createVirtualDisplay(
            "DeviceAgentScreenCapture",
            w, h, d,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface, null, null
        )
        return virtualDisplay != null
    }

    /** Item 73: rotation/resolution badalne par display + reader dobara size karo. */
    private fun resizeDisplay() {
        if (released) return
        val (w, h, d) = currentMetrics()
        if (w <= 0 || h <= 0 || (w == width && h == height)) return
        val display = virtualDisplay ?: return

        val oldReader = imageReader
        val newReader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3)
        try {
            display.resize(w, h, d)
            display.surface = newReader.surface
        } catch (e: Exception) {
            newReader.close()
            return
        }
        imageReader = newReader
        width = w; height = h; density = d
        newReader.setOnImageAvailableListener(
            if (streaming) streamListener else idleListener, frameHandler
        )
        oldReader?.setOnImageAvailableListener(null, null)
        synchronized(heldLock) {
            heldImage?.close() // purane reader ki image — reader close se pehle
            heldImage = null
        }
        oldReader?.close()
    }

    /**
     * Item 62: screenshot — held (latest) frame se. Static screen par bhi
     * kaam karta hai kyunki frame hold hai; sirf pehla frame aane se
     * pehle null deta hai.
     */
    fun captureLatestFrameAsPng(): ByteArray? {
        val bitmap: Bitmap = synchronized(heldLock) {
            val image = heldImage ?: return null
            try {
                imageToBitmap(image)
            } catch (e: Exception) {
                return null
            }
        }
        try {
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 90, out)
            return out.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }

    private fun imageToBitmap(image: Image): Bitmap {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val pixelStride = plane.pixelStride
        val rowStride = plane.rowStride
        val rowPadding = rowStride - pixelStride * image.width

        val paddedBitmap = Bitmap.createBitmap(
            image.width + rowPadding / pixelStride, image.height, Bitmap.Config.ARGB_8888
        )
        paddedBitmap.copyPixelsFromBuffer(buffer)

        if (rowPadding == 0) return paddedBitmap // koi crop zaroori nahi, fast path

        val cropped = Bitmap.createBitmap(paddedBitmap, 0, 0, image.width, image.height)
        paddedBitmap.recycle() // memory leak se bachne ke liye — yeh per-frame chalta hai
        return cropped
    }

    /** Item 63: bandwidth/CPU bachane ke liye stream frames width <= 720px. */
    private fun downscale(src: Bitmap): Bitmap {
        val maxW = streamMaxWidth
        if (src.width <= maxW) return src
        val ratio = maxW.toFloat() / src.width
        val h = (src.height * ratio).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(src, maxW, h, true)
    }

    fun startStreaming(
        fps: Int = DEFAULT_STREAM_FPS,
        maxWidth: Int = DEFAULT_STREAM_MAX_WIDTH,
        jpegQuality: Int = DEFAULT_STREAM_JPEG_QUALITY,
        onFrame: (ByteArray) -> Unit
    ) {
        streamMinIntervalMs = 1000L / fps.coerceIn(1, 30)
        streamMaxWidth = maxWidth.coerceIn(240, 1440)
        streamJpegQuality = jpegQuality.coerceIn(20, 95)
        streamCallback = onFrame
        lastStreamAt = 0L
        streaming = true
        imageReader?.setOnImageAvailableListener(streamListener, frameHandler)
    }

    fun stopStreaming() {
        streaming = false
        streamCallback = null
        if (!released) {
            imageReader?.setOnImageAvailableListener(idleListener, frameHandler)
        }
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Screen sharing",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Device Agent")
            .setContentText("Screen is being shared")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .build()
    }

    /** Idempotent: onStop callback aur onDestroy dono se safely call hota hai. */
    private fun releaseCapture() {
        if (released) return
        released = true
        streaming = false
        streamCallback = null
        try {
            applicationContext.unregisterComponentCallbacks(componentCallbacks)
        } catch (_: Exception) {}
        imageReader?.setOnImageAvailableListener(null, null)
        synchronized(heldLock) {
            heldImage?.close()
            heldImage = null
        }
        try { virtualDisplay?.release() } catch (_: Exception) {}
        virtualDisplay = null
        try { mediaProjection?.unregisterCallback(projectionCallback) } catch (_: Exception) {}
        stopAudioStreaming()
        try { mediaProjection?.stop() } catch (_: Exception) {}
        mediaProjection = null
        try { imageReader?.close() } catch (_: Exception) {}
        imageReader = null
        frameThread?.quitSafely()
        frameThread = null
        frameHandler = null
        instance = null
    }

    override fun onDestroy() {
        releaseCapture()
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
