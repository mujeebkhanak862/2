package com.deviceagent.app

import android.content.Intent
import android.content.pm.PackageManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of `ChannelNames.appLauncher` — matches Dart's
 * `AppLauncherBridge`. `identifier` Android par package name hai
 * (jaise "com.spotify.music").
 */
class AppLauncherHandler(private val activity: HandlerHost) {

    fun register(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ChannelNames.appLauncher
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "launchApp" -> launchApp(call.argument("identifier") ?: "", result)
                "isAppInstalled" -> isAppInstalled(call.argument("identifier") ?: "", result)
                "listInstalledApps" -> listInstalledApps(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun launchApp(packageName: String, result: MethodChannel.Result) {
        val pm = activity.packageManager
        val intent = pm.getLaunchIntentForPackage(packageName)
        if (intent == null) {
            result.error("NOT_FOUND", "App install nahi hai: $packageName", null)
            return
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(intent)
        result.success(true)
    }

    private fun isAppInstalled(packageName: String, result: MethodChannel.Result) {
        val pm = activity.packageManager
        val installed = try {
            pm.getPackageInfo(packageName, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
        result.success(installed)
    }

    private fun listInstalledApps(result: MethodChannel.Result) {
        val pm = activity.packageManager
        val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
            // System apps ke bahut saare "invisible" components chhod dete hain —
            // sirf woh apps dikhate hain jinke paas ek launcher-visible icon/entry hai.
            .filter { pm.getLaunchIntentForPackage(it.packageName) != null }
            .map {
                mapOf(
                    "identifier" to it.packageName,
                    "name" to pm.getApplicationLabel(it).toString()
                )
            }
        result.success(apps)
    }
}
