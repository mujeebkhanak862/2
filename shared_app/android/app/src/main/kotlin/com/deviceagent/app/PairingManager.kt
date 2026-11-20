package com.deviceagent.app

import android.content.Context
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom

/**
 * Native side of `ChannelNames.pairing` ("device_agent/pairing") from
 * platform_channel_bridge.dart. Dart calls `generatePairingCode`; yeh
 * device ki stable identity (ANDROID_ID) aur ek short-lived pairing code
 * return karta hai jo Control API ke saath device ko link karta hai.
 *
 * Yeh module khud sirf LOCALLY code generate karta hai — asal Control
 * API registration (`POST /devices/pair`) Dart side se hoti hai
 * (`main.dart`'s `_onPaired()` -> `api_client.dart`'s `pairDevice()`).
 * (Stale comment fix: pehle yahan likha tha ke yeh wiring "abhi baaki
 * hai" — woh already complete ho chuki hai, `main.dart` mein dekhein.)
 */
object PairingManager {
    private val CHANNEL = ChannelNames.pairing
    private val secureRandom = SecureRandom()

    fun register(flutterEngine: FlutterEngine, context: Context) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "generatePairingCode" -> {
                    try {
                        val deviceId = deviceId(context)
                        val code = generateCode()
                        // Dashboard side is app ko is code se pehchanta hai
                        // jab tak QR scan/manual entry confirm na ho.
                        result.success("$code")
                        android.util.Log.d(
                            "PairingManager",
                            "Generated pairing code for device=$deviceId"
                        )
                    } catch (e: Exception) {
                        result.error(
                            "PAIRING_FAILED",
                            "Pairing code generate nahi ho saka: ${e.message}",
                            null
                        )
                    }
                }
                "getDeviceId" -> result.success(deviceId(context))
                else -> result.notImplemented()
            }
        }
    }

    /** Stable per-install identity. Reinstall par badal jaata hai. */
    private fun deviceId(context: Context): String {
        return Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ANDROID_ID
        ) ?: "unknown-device"
    }

    /** 6-digit human-typeable code, jaisa TVs/smart-speakers pairing flows mein hota hai. */
    private fun generateCode(): String {
        val n = 100000 + secureRandom.nextInt(900000)
        return n.toString()
    }
}
