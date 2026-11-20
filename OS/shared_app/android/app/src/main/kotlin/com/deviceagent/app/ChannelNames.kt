package com.deviceagent.app

/**
 * Mirrors `ChannelNames` in `shared_app/lib/platform_channels/platform_channel_bridge.dart`.
 * Dono files mein exact same strings honi chahiye — yahan badlo to Dart
 * side bhi badalna (aur vice versa).
 */
object ChannelNames {
    const val screenCapture = "device_agent/screen_capture"
    const val screenLiveStream = "device_agent/screen_live_stream"
    const val input = "device_agent/input"
    const val files = "device_agent/files"
    const val appLauncher = "device_agent/app_launcher"
    const val browser = "device_agent/browser"
    const val clipboard = "device_agent/clipboard"
    const val pairing = "device_agent/pairing"
    const val locationNetwork = "device_agent/location_network"
    const val contacts = "device_agent/contacts"
    const val notifications = "device_agent/notifications"
    const val background = "device_agent/background"
    // Item 85 (headless): headless engine ka Dart -> native control channel.
    const val headless = "device_agent/headless"

    // Audit fix (P1-05) — real lock/sleep/screen-off state.
    const val lockState = "device_agent/lock_state"
    const val lockStateEvents = "device_agent/lock_state_events"
}
