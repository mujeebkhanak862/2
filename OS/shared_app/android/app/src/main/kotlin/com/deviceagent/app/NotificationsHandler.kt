package com.deviceagent.app

import android.content.ComponentName
import android.content.Intent
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Item 84: Dart <-> [DeviceNotificationListener] bridge. */
class NotificationsHandler(private val activity: HandlerHost) {

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ChannelNames.notifications)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isEnabled" -> result.success(isEnabled())
                    "openSettings" -> {
                        activity.startActivity(
                            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(null)
                    }
                    "getRecent" -> {
                        if (!isEnabled()) {
                            result.error(
                                "PERMISSION_DENIED",
                                "Notification access enable nahi hai (Settings > Notification access)",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        val limit = call.argument<Int>("limit") ?: 20
                        val since = (call.argument<Number>("since_ms") ?: 0L).toLong()
                        result.success(
                            NotificationFilter.filter(
                                activity.applicationContext,
                                DeviceNotificationListener.recent(limit, since)
                            )
                        )
                    }
                    // Local-only per-app filter (UI se); remote API se nahi badalta.
                    "getBlockedPackages" ->
                        result.success(NotificationFilter.blocked(activity.applicationContext).toList())
                    "setBlockedPackages" -> {
                        val list = call.argument<List<String>>("packages") ?: emptyList()
                        NotificationFilter.setBlocked(activity.applicationContext, list.toSet())
                        result.success(null)
                    }
                    "getMessagingEvents", "prepareReply", "sendReply" -> {
                        if (!isEnabled()) {
                            result.error(
                                "PERMISSION_DENIED",
                                "Notification access enable nahi hai (Settings > Notification access)",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            when (call.method) {
                                "getMessagingEvents" -> result.success(
                                    NotificationFilter.filter(
                                        activity.applicationContext,
                                        MessagingStore.getEvents(
                                            call.argument<Int>("limit") ?: 20,
                                            (call.argument<Number>("since_ms") ?: 0L).toLong(),
                                            call.argument<String>("package"),
                                        )
                                    )
                                )
                                "prepareReply" -> result.success(
                                    MessagingStore.prepareReply(
                                        call.argument<String>("event_id") ?: "",
                                        call.argument<String>("text") ?: "",
                                    )
                                )
                                else -> result.success(
                                    MessagingStore.sendReply(
                                        activity.applicationContext,
                                        call.argument<String>("draft_id") ?: "",
                                    )
                                )
                            }
                        } catch (e: MessagingException) {
                            result.error(e.code, e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isEnabled(): Boolean =
        NotificationManagerCompat.getEnabledListenerPackages(activity).contains(activity.packageName)
}
