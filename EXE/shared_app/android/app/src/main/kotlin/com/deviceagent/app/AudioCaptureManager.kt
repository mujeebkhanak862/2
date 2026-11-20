package com.deviceagent.app

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Handler
import android.os.HandlerThread

/**
 * Stage 9.2 — device ki system audio (jo bhi chal raha ho: video, music, call ki
 * dusri taraf nahi — sirf playback) capture karta hai, taaki website/dashboard par
 * screen ke saath awaaz bhi sunai de.
 *
 * Kaise kaam karta hai:
 *  - Android 10+ (Q, API 29) ka `AudioPlaybackCaptureConfiguration` use karta hai —
 *    isi `MediaProjection` session se jo screen capture ke liye pehle se maujood hai
 *    (user ek hi consent dialog dekhta hai, dono ke liye).
 *  - Raw PCM: 16 kHz, mono, 16-bit — chhota bandwidth (~32 KB/s) aur compress/decode
 *    ki zaroorat nahi (website seedha Web Audio API se bajati hai).
 *  - Compressed codec (Opus/AAC) jaan-boojh kar NAHI — platform API har Android
 *    version/OEM par alag tarah available/buggy ho sakta hai; raw PCM hamesha kaam
 *    karta hai aur latency bhi kam rehti hai.
 *
 * **Known limits:**
 *  - DRM-protected playback (`setAllowedCapturePolicy` ALLOW_CAPTURE_BY_NONE wale
 *    apps — jaise kai streaming apps) capture nahi hoti — khamoshi (silence) aati
 *    hai, crash nahi. Yeh Android ka rule hai, bypass nahi kiya ja sakta.
 *  - Calls/mic audio capture NAHI hota — sirf playback (media/game/etc).
 */
class AudioCaptureManager(private val mediaProjection: MediaProjection) {

    companion object {
        const val SAMPLE_RATE = 16_000
        private const val CHANNEL = AudioFormat.CHANNEL_IN_MONO
        private const val ENCODING = AudioFormat.ENCODING_PCM_16BIT
        // 20ms chunks @16kHz mono 16-bit = 320 samples = 640 bytes — chhota
        // latency (video chunking jaisa) rakhne ke liye.
        const val CHUNK_BYTES = 640

        fun isSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
    }

    @Volatile private var record: AudioRecord? = null
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    @Volatile private var running = false

    /** `onChunk` background thread par call hota hai — caller UI thread khud switch kare. */
    @SuppressLint("MissingPermission") // RECORD_AUDIO manifest mein hai; runtime grant MainActivity karta hai
    fun start(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit): Boolean {
        if (!isSupported()) {
            onError("AUDIO_UNSUPPORTED: system audio capture Android 10+ chahiye")
            return false
        }
        if (running) return true
        val config = try {
            AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .addMatchingUsage(android.media.AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(android.media.AudioAttributes.USAGE_GAME)
                .addMatchingUsage(android.media.AudioAttributes.USAGE_UNKNOWN)
                .build()
        } catch (e: Exception) {
            onError("AUDIO_CONFIG_FAILED: ${e.message}")
            return false
        }
        val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL, ENCODING)
        if (minBuf <= 0) {
            onError("AUDIO_BUFFER_UNAVAILABLE")
            return false
        }
        val rec = try {
            AudioRecord.Builder()
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(ENCODING)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(CHANNEL)
                        .build()
                )
                .setBufferSizeInBytes(minBuf * 4)
                .setAudioPlaybackCaptureConfig(config)
                .build()
        } catch (e: Exception) {
            onError("AUDIO_RECORD_INIT_FAILED: ${e.message}")
            return false
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            onError("AUDIO_RECORD_NOT_INITIALIZED")
            rec.release()
            return false
        }
        record = rec
        val t = HandlerThread("AudioCapture").also { it.start() }
        thread = t
        handler = Handler(t.looper)
        running = true
        try {
            rec.startRecording()
        } catch (e: Exception) {
            onError("AUDIO_START_FAILED: ${e.message}")
            stop()
            return false
        }
        handler?.post {
            val buf = ByteArray(CHUNK_BYTES)
            while (running) {
                val r = try {
                    rec.read(buf, 0, buf.size)
                } catch (_: Exception) {
                    break
                }
                if (r > 0) {
                    onChunk(if (r == buf.size) buf.copyOf() else buf.copyOf(r))
                } else if (r < 0) {
                    break // AudioRecord.ERROR_* — stream kharab, ruk jao
                }
            }
        }
        return true
    }

    fun stop() {
        running = false
        try { record?.stop() } catch (_: Exception) {}
        try { record?.release() } catch (_: Exception) {}
        record = null
        thread?.quitSafely()
        thread = null
        handler = null
    }
}
