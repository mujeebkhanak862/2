package com.deviceagent.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Item 85 (headless): UI (Activity) ke bina agent chalane wala Flutter
 * engine. Foreground service ke andar host hota hai, Dart entrypoint
 * `agentMain` (lib/protocol/headless_agent.dart) agent connection +
 * status reporting chalata hai — UI nahi.
 *
 * Ownership rule: ek waqt mein sirf ek engine agent chalata hai.
 *  - Activity band/swipe-away => service [start] karti hai.
 *  - Activity dobara khulti hai => `MainActivity.onCreate` [stop] karti
 *    hai (UI engine agent ka maalik ban jata hai).
 *
 * Limits (honest): UI-only cheezein (screen-capture consent, permission
 * dialogs, folder picker) headless mein `NEEDS_UI` deti hain — app kholni
 * padti hai. Baaki (location/status, apps, notifications+messaging,
 * accessibility input, files on already-granted tree) kaam karte hain.
 */
object HeadlessAgent {
    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var registrar: ChannelRegistrar? = null

    /** Main thread par chalao. Zinda ho to no-op. */
    fun start(context: Context) {
        main.post {
            if (engine != null) return@post
            // Race guard: post hone ke beech user app dobara khol de to UI engine
            // maalik hai — do agent connections nahi.
            if (AgentRuntime.uiEngineAttached) return@post
            val app = context.applicationContext
            try {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(app)
                loader.ensureInitializationComplete(app, null)

                // Plugins (flutter_secure_storage waghera) FlutterEngine(Context)
                // khud register karta hai — credentials isi se load hote hain.
                val e = FlutterEngine(app)
                val host = HandlerHost(app, null)
                registrar = ChannelRegistrar(host).also { it.registerAll(e) }

                MethodChannel(e.dartExecutor.binaryMessenger, ChannelNames.headless)
                    .setMethodCallHandler { call, result ->
                        when (call.method) {
                            // Dart: credentials nahi mile / server ne unpair kiya /
                            // doosra instance ('replaced') chal raha hai.
                            "stopSelf" -> {
                                result.success(null)
                                main.post {
                                    stop(app)
                                    // Credentials nahi / unpaired / replaced: agent mode
                                    // band karo, warna sticky restart baar-baar ek
                                    // bekaar engine banata aur notification "NOT running"
                                    // dikhata rehta. UI se dobara enable ho sakta hai.
                                    AgentRuntime.persistAgentMode(app, false)
                                    try {
                                        app.stopService(
                                            android.content.Intent(app, AgentForegroundService::class.java)
                                        )
                                    } catch (_: Throwable) {}
                                }
                            }
                            else -> result.notImplemented()
                        }
                    }

                e.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(
                        loader.findAppBundlePath(),
                        "package:shared_app/protocol/headless_agent.dart",
                        "agentMain",
                    )
                )
                engine = e
                AgentRuntime.headlessRunning = true
                AgentForegroundService.refreshNotification(app)
            } catch (t: Throwable) {
                android.util.Log.e("HeadlessAgent", "start failed", t)
                engine = null
                AgentRuntime.headlessRunning = false
                AgentForegroundService.refreshNotification(app)
            }
        }
    }

    /** Engine (aur uska agent socket) band. */
    fun stop(context: Context) {
        main.post {
            val e = engine ?: return@post
            engine = null
            AgentRuntime.headlessRunning = false
            try { registrar?.dispose() } catch (_: Throwable) {}
            registrar = null
            try { e.destroy() } catch (t: Throwable) {
                android.util.Log.w("HeadlessAgent", "destroy failed", t)
            }
            AgentForegroundService.refreshNotification(context.applicationContext)
        }
    }

    /** UI engine ke liye synchronous-ish handoff (MainActivity.onCreate). */
    fun stopNow(context: Context) {
        val e = engine ?: return
        engine = null
        AgentRuntime.headlessRunning = false
        try { registrar?.dispose() } catch (_: Throwable) {}
        registrar = null
        try { e.destroy() } catch (_: Throwable) {}
        AgentForegroundService.refreshNotification(context.applicationContext)
    }
}
