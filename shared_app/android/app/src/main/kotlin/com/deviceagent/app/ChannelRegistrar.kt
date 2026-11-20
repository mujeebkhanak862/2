package com.deviceagent.app

import io.flutter.embedding.engine.FlutterEngine

/**
 * Item 85 (headless): saare capability handlers ek jagah register hote
 * hain — `MainActivity` (UI engine) aur `HeadlessAgent` (headless engine)
 * dono yahi use karte hain, isliye dono engines mein same capabilities.
 */
class ChannelRegistrar(private val host: HandlerHost) {
    // Activity-result/permission callbacks ke liye MainActivity inhe use karti hai.
    lateinit var screenCapture: ScreenCaptureHandler
        private set
    lateinit var files: FilesHandler
        private set
    lateinit var locationNetwork: LocationNetworkHandler
        private set
    lateinit var contacts: ContactsHandler
        private set
    private var lockState: LockStateHandler? = null

    /** Engine destroy se pehle: receivers/streams saaf. */
    fun dispose() {
        lockState?.dispose()
        if (::screenCapture.isInitialized) screenCapture.dispose()
    }

    fun registerAll(engine: FlutterEngine) {
        PairingManager.register(engine, host)

        screenCapture = ScreenCaptureHandler(host).also { it.register(engine) }
        InputHandler(host).register(engine)
        files = FilesHandler(host).also { it.register(engine) }
        AppLauncherHandler(host).register(engine)
        ClipboardHandler(host).register(engine)
        BrowserHandler(host).register(engine)
        locationNetwork = LocationNetworkHandler(host).also { it.register(engine) }
        contacts = ContactsHandler(host).also { it.register(engine) }
        // Audit fix (P1-05) — real lock/sleep/screen-off state.
        lockState = LockStateHandler(host).also { it.register(engine) }
        NotificationsHandler(host).register(engine)
        BackgroundHandler(host).register(engine)
        // Aage: naye capabilities isi jagah register honge.
    }
}
