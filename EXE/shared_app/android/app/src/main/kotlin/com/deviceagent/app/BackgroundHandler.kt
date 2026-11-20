package com.deviceagent.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Item 85: Dart <-> [AgentForegroundService] + battery-optimization helpers. */
class BackgroundHandler(private val activity: HandlerHost) {

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ChannelNames.background)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        activity.agentModeEnabled = true
                        val intent = Intent(activity, AgentForegroundService::class.java)
                        try {
                            activity.startForegroundService(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            // Android 12+: background se start restricted ho sakta hai.
                            result.error("START_FAILED", e.message, null)
                        }
                    }
                    "stopService" -> {
                        activity.agentModeEnabled = false
                        activity.stopService(Intent(activity, AgentForegroundService::class.java))
                        result.success(true)
                    }
                    "isRunning" -> result.success(AgentForegroundService.running)
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = activity.getSystemService(android.content.Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(activity.packageName))
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                            .setData(Uri.parse("package:${activity.packageName}"))
                        try {
                            activity.startActivity(intent)
                        } catch (e: Exception) {
                            activity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
