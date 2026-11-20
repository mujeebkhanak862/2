import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../protocol/api_client.dart';
import '../protocol/command_envelope.dart';
import '../protocol/event_envelope.dart';
import '../protocol/websocket_client.dart';
import '../theme/app_theme.dart';
import 'step_timeline.dart';

enum ViewingMode { snapshot, live, hybrid }

extension on ViewingMode {
  String get wireValue => switch (this) {
        ViewingMode.snapshot => 'snapshot',
        ViewingMode.live => 'live',
        ViewingMode.hybrid => 'hybrid',
      };
}

/// Section 2.2 — Task Monitor Dashboard: live preview, current action
/// label, step timeline, pause/stop — teeno viewing modes (Snapshot/Live/
/// Hybrid) ke saath.
///
/// **P1-03**: pehle live preview sirf ek hardcoded placeholder text
/// tha (`StreamBuilder`'s `builder` khud `snap` argument ko ignore kar
/// raha tha) — actual frame kabhi nahi dikhti thi, chahe stream kitni
/// bhi frames bhej rahi ho. Ab real base64 JPEG frames decode ho kar
/// dikhti hain, fullscreen preview hai, aur pause/resume/stop UI ab
/// server ke authoritative `task_state` events (P0-01/P0-02) se sync
/// rehta hai — pehle sirf client-side optimistic guess tha.
class TaskMonitorScreen extends StatefulWidget {
  final DeviceAgentApiClient api;
  final Uri wsBaseUrl;
  final String sessionId;

  const TaskMonitorScreen({
    super.key,
    required this.api,
    required this.wsBaseUrl,
    required this.sessionId,
  });

  @override
  State<TaskMonitorScreen> createState() => _TaskMonitorScreenState();
}

class _TaskMonitorScreenState extends State<TaskMonitorScreen> {
  late final SessionEventChannel _events;
  LiveScreenChannel? _liveScreen;
  StreamSubscription<DeviceAgentEvent>? _sub;

  final List<TaskProgressEvent> _steps = [];
  String _currentAction = 'Waiting for task...';
  ViewingMode _mode = ViewingMode.snapshot; // Section 2.1 default

  /// Server ka authoritative task state (`RUNNING`/`PAUSED`/`STOPPED`/...)
  /// — `task_state` event se aata hai (P0-01/P0-02). `null` jab tak
  /// server se pehla confirmation na mila ho.
  String? _taskState;

  /// Sirf UI-level flicker/debounce ke liye — asal source-of-truth
  /// `_taskState` hi hai (server-confirmed). Button ke click ke turant
  /// baad, jawab aane tak, disable rehta hai taaki double-tap se do
  /// baar pause/resume na chala jaaye.
  bool _pauseResumeInFlight = false;

  /// Har naye tap/swipe/type_text step ke baad chhoti si overlay badge
  /// dikhane ke liye — honest hai (sirf "kya ho raha hai" batata hai,
  /// screen par kahan hua yeh nahi claim karta, kyunki hamare paas
  /// device ke screen resolution ka pakka pata nahi hai is coordinate
  /// system ko accurately map karne ke liye — galat position dikhana
  /// sahi na dikhane se bhi bura hota).
  Timer? _overlayTimer;
  String? _overlayLabel;

  // Item 89: connection/stream indicators. Channel khud connection-state
  // expose nahi karta, isliye hum observable cheezon se honestly infer
  // karte hain (last event time, frames/sec) — latency measure nahi ho
  // sakti (frames par timestamp nahi), isliye dikhayi bhi nahi jaati.
  DateTime? _lastEventAt;
  bool _eventsError = false;
  Timer? _tick;
  LiveScreenChannel? _countedChannel;
  StreamSubscription<dynamic>? _frameSub;
  int _frameCount = 0;
  int _fps = 0;
  DateTime? _lastFrameAt;
  bool _streamClosed = false;

  /// Item 34: snapshot mode ke liye `screen.capture` ka latest result.
  Uint8List? _snapshotBytes;
  bool _snapshotLoading = false;

  @override
  void initState() {
    super.initState();
    // Items 26/27: bearer token ke saath connect; channel khud reconnect
    // with backoff karta hai (session abhi server ko pata na ho ya
    // network gire to bhi), aur stream error ab handle hota hai.
    _events = SessionEventChannel.connect(widget.wsBaseUrl, widget.sessionId,
        bearerToken: widget.api.bearerToken);
    _sub = _events.events.listen(_onEvent, onError: (_) {
      if (mounted) setState(() => _eventsError = true);
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _onTick() {
    if (!mounted) return;
    // Live channel badla ho to frame counter naye channel par lagao.
    if (!identical(_liveScreen, _countedChannel)) {
      _frameSub?.cancel();
      _frameSub = null;
      _countedChannel = _liveScreen;
      _frameCount = 0;
      _lastFrameAt = null;
      _streamClosed = false;
      final ch = _countedChannel;
      if (ch != null) {
        _frameSub = ch.frames.listen(
          (_) {
            _frameCount++;
            _lastFrameAt = DateTime.now();
          },
          onError: (_) => _streamClosed = true,
          onDone: () => _streamClosed = true,
        );
      }
    }
    setState(() {
      _fps = _frameCount;
      _frameCount = 0;
    });
  }

  void _onEvent(DeviceAgentEvent event) {
    _lastEventAt = DateTime.now();
    _eventsError = false;
    if (event is TaskProgressEvent) {
      setState(() {
        _steps.add(event);
        _currentAction = event.description;
      });
      _showActionOverlay(event.action);
    } else if (event is SwitchEvent && event.switchType == 'viewing_mode') {
      setState(() {
        _mode = ViewingMode.values
            .firstWhere((m) => m.wireValue == event.newValue, orElse: () => _mode);
      });
    } else if (event is TaskStateEvent) {
      setState(() {
        _taskState = event.state;
        _pauseResumeInFlight = false;
      });
      // Server ne confirm kar diya ke task PAUSED ya STOPPED ho gaya —
      // agar live stream chal rahi thi, UI-side bhi band kar dete hain
      // (device-side yeh khud bhi karta hai — P1-03 — yeh sirf dashboard
      // ka apna connection saaf karta hai taaki koi dead socket na rahe).
      if ((event.state == 'PAUSED' || event.state == 'STOPPED') && _liveScreen != null) {
        _liveScreen?.close();
        setState(() {
          _liveScreen = null;
          if (_mode != ViewingMode.snapshot) _mode = ViewingMode.snapshot;
        });
      }
    }
  }

  /// Honest overlay — sirf action *type* dikhata hai (tap/swipe/type),
  /// koi fake coordinate/position claim nahi karta.
  void _showActionOverlay(String action) {
    String? label;
    if (action == 'input.tap') {
      label = '👆 Tap';
    } else if (action == 'input.swipe') {
      label = '↔️ Swipe';
    } else if (action == 'input.type_text') {
      label = '⌨️ Typing';
    } else {
      return; // baaki actions ke liye overlay nahi dikhate
    }
    _overlayTimer?.cancel();
    setState(() => _overlayLabel = label);
    _overlayTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _overlayLabel = null);
    });
  }

  /// "Watch Live" button — Hybrid mode mein turant live stream shuru karta
  /// hai bina task rukwaaye (Section 2.1 & 2.2).
  Future<void> _watchLive() async {
    try {
      final res = await widget.api.sendCommand(
        capability: 'screen',
        action: 'screen.watch_live',
        params: {'session_id': widget.sessionId},
      );
      // HTTP 200 ke andar bhi device `error_code` de sakti hai (jaise
      // PERMISSION_REQUIRED) — pehle yahan tab bhi connect kar liya jata tha.
      if (res['error_code'] != null || res['started'] != true) {
        throw '${res['error_code'] ?? 'NOT_STARTED'}: ${res['message'] ?? 'live stream shuru nahi hui'}';
      }
      if (!mounted) return;
      setState(() {
        _liveScreen = LiveScreenChannel.connect(widget.wsBaseUrl, widget.sessionId,
            bearerToken: widget.api.bearerToken);
        _mode = ViewingMode.hybrid;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Watch Live failed: $e')));
    }
  }

  Future<void> _stopLive() async {
    // Item 31: `session_id` required hai (pehle missing tha => hamesha
    // 400) aur exception ab UI ko atkata nahi.
    try {
      await widget.api.sendCommand(
        capability: 'screen',
        action: 'screen.stop_live',
        params: {'session_id': widget.sessionId},
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Stop live failed: $e')));
      }
    }
    await _liveScreen?.close();
    if (!mounted) return;
    setState(() {
      _liveScreen = null;
      _mode = ViewingMode.snapshot;
    });
  }

  /// Item 34: snapshot ab sach mein dikhta hai — `screen.capture` command
  /// ka base64 result decode karke.
  Future<void> _refreshSnapshot() async {
    if (_snapshotLoading) return;
    setState(() => _snapshotLoading = true);
    try {
      final result = await widget.api.sendCommand(
        capability: 'screen',
        action: 'screen.capture',
        params: {'session_id': widget.sessionId},
      );
      final b64 = result['screenshot'];
      if (b64 is String && b64.isNotEmpty) {
        final bytes = base64Decode(b64);
        if (!mounted) return;
        setState(() => _snapshotBytes = bytes);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Screenshot nahi mila (screen-capture permission check karein)')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Snapshot failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _snapshotLoading = false);
    }
  }

  Future<void> _setMode(ViewingMode mode) async {
    if (mode == ViewingMode.live && _liveScreen == null) {
      await _watchLive();
      return;
    }
    if (mode != ViewingMode.live && _liveScreen != null) {
      await _stopLive();
    }
    try {
      await widget.api.switchSession(
        sessionId: widget.sessionId,
        switchType: SwitchType.viewingMode,
        value: mode.wireValue,
      );
      setState(() => _mode = mode);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Mode switch failed: $e')));
    }
  }

  bool get _isPaused => _taskState == 'PAUSED';

  Future<void> _togglePauseResume() async {
    setState(() => _pauseResumeInFlight = true);
    try {
      await widget.api.sendCommand(
        capability: 'control',
        action: _isPaused ? 'control.resume' : 'control.pause',
        params: {'session_id': widget.sessionId},
      );
      // NOTE: `_taskState` yahan turant set NAHI karte — server ka
      // `task_state` event (upar `_onEvent`) hi authoritative update
      // deta hai. Yeh command call sirf request bhejta hai; agar yeh
      // fail ho jaaye (network/scope issue), toggle apne aap "stuck"
      // nahi rehta kyunki humne optimistically state badli hi nahi.
    } catch (e) {
      setState(() => _pauseResumeInFlight = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _stopTask() async {
    // Item 89: destructive action ke liye confirmation.
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop task?'),
        content: const Text(
            'Task turant cancel ho jayega aur resume nahi hoga (Pause se '
            'baad mein continue kar sakte hain).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Stop')),
        ],
      ),
    );
    if (sure != true) return;
    try {
      await widget.api.sendCommand(
        capability: 'control',
        action: 'control.stop',
        params: {'session_id': widget.sessionId},
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Stop failed: $e')));
    }
  }

  void _openFullscreen() {
    if (_mode == ViewingMode.snapshot) return; // snapshot ke liye fullscreen ki zaroorat nahi
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _FullscreenLivePreview(frames: _liveScreen?.frames),
    ));
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    _tick?.cancel();
    _frameSub?.cancel();
    _sub?.cancel();
    _events.close();
    _liveScreen?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Task Monitor'),
        actions: [
          // Section 2.2 — Pause/Stop button, hamesha visible. Server-
          // confirmed state se disable hota hai jab tak response na aaye.
          IconButton(
            icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
            tooltip: _isPaused ? 'Resume' : 'Pause',
            onPressed: _pauseResumeInFlight ? null : _togglePauseResume,
          ),
          IconButton(
            icon: const Icon(Icons.stop_circle_outlined),
            tooltip: 'Stop',
            onPressed: _stopTask,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_taskState != null) _buildTaskStateBanner(),
          _buildConnectionBar(),
          _buildPreview(),
          _buildModeSwitcher(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_currentAction,
                  style: Theme.of(context).textTheme.titleSmall),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: StepTimeline(steps: _steps)),
        ],
      ),
    );
  }

  /// Item 89: live connection indicator + stream state (FPS) + reconnect.
  Widget _buildConnectionBar() {
    final now = DateTime.now();
    final sinceEvent =
        _lastEventAt == null ? null : now.difference(_lastEventAt!).inSeconds;

    final StatusChip events;
    if (_eventsError) {
      events = const StatusChip(
          label: 'Connection problem · reconnecting…',
          tone: StatusTone.danger,
          icon: Icons.sync_problem);
    } else if (sinceEvent == null) {
      events = const StatusChip(
          label: 'Waiting for first event…',
          tone: StatusTone.neutral,
          icon: Icons.hourglass_empty);
    } else if (sinceEvent <= 15) {
      events = StatusChip(
          label: 'Live · updated ${sinceEvent}s ago',
          tone: StatusTone.success,
          icon: Icons.sensors);
    } else {
      events = StatusChip(
          label: 'Quiet · last update ${sinceEvent}s ago',
          tone: StatusTone.warning,
          icon: Icons.sensors_off);
    }

    StatusChip? stream;
    if (_liveScreen != null) {
      final sinceFrame =
          _lastFrameAt == null ? null : now.difference(_lastFrameAt!).inSeconds;
      if (_streamClosed) {
        stream = const StatusChip(
            label: 'Stream closed',
            tone: StatusTone.danger,
            icon: Icons.videocam_off);
      } else if (sinceFrame == null) {
        stream = const StatusChip(
            label: 'Stream connecting…',
            tone: StatusTone.neutral,
            icon: Icons.videocam);
      } else if (sinceFrame > 3) {
        stream = StatusChip(
            label: 'Stream stalled (${sinceFrame}s)',
            tone: StatusTone.warning,
            icon: Icons.videocam_off);
      } else {
        stream = StatusChip(
            label: 'Streaming · $_fps FPS',
            tone: StatusTone.success,
            icon: Icons.videocam);
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: Spacing.lg, vertical: Spacing.sm),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.xs,
          children: [events, if (stream != null) stream],
        ),
      ),
    );
  }

  Widget _buildTaskStateBanner() {
    final isPaused = _taskState == 'PAUSED';
    final isStopped = _taskState == 'STOPPED' || _taskState == 'COMPLETED' || _taskState == 'FAILED';
    if (!isPaused && !isStopped) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final bg = isStopped ? scheme.errorContainer : scheme.tertiaryContainer;
    final fg = isStopped ? scheme.onErrorContainer : scheme.onTertiaryContainer;
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(
          horizontal: Spacing.lg, vertical: Spacing.sm),
      child: Row(
        children: [
          Icon(isStopped ? Icons.stop_circle_outlined : Icons.pause_circle_outline,
              color: fg, size: 18),
          const SizedBox(width: Spacing.sm),
          Text(
            isStopped ? 'Task stopped ($_taskState)' : 'Task paused',
            style: TextStyle(color: fg, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  /// Live screen preview (thumbnail, click karke fullscreen) — Section 2.2.
  /// Snapshot mode mein latest step ka screenshot_url dikhta hai; Live/Hybrid
  /// mode mein `LiveScreenChannel` se continuous frames, **actual decode
  /// karke** (P1-03 fix — pehle yahan hardcoded placeholder text tha).
  Widget _buildPreview() {
    return GestureDetector(
      onTap: _openFullscreen,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              color: Colors.black87,
              alignment: Alignment.center,
              child: _mode == ViewingMode.snapshot
                  ? _buildSnapshotPreview()
                  : _buildLiveFramePreview(_liveScreen?.frames),
            ),
            if (_overlayLabel != null) _buildActionOverlayBadge(),
            if (_mode == ViewingMode.snapshot && _snapshotBytes != null)
              Positioned(
                right: 8,
                bottom: 8,
                child: IconButton(
                  icon: _snapshotLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh, color: Colors.white70),
                  tooltip: 'Refresh snapshot',
                  onPressed: _refreshSnapshot,
                ),
              ),
            if (_mode != ViewingMode.snapshot)
              const Positioned(
                right: 8,
                bottom: 8,
                child: Icon(Icons.fullscreen, color: Colors.white70, size: 20),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSnapshotPreview() {
    final bytes = _snapshotBytes;
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true);
    }
    final url = _steps.isNotEmpty ? _steps.last.screenshotUrl : null;
    if (url == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Snapshot preview', style: TextStyle(color: Colors.white54)),
          const SizedBox(height: 8),
          if (_snapshotLoading)
            const CircularProgressIndicator(color: Colors.white54)
          else
            TextButton.icon(
              onPressed: _refreshSnapshot,
              icon: const Icon(Icons.camera_alt_outlined, color: Colors.white70),
              label: const Text('Take snapshot',
                  style: TextStyle(color: Colors.white70)),
            ),
        ],
      );
    }
    return Image.network(
      url,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) =>
          const Text('Screenshot load nahi ho saka', style: TextStyle(color: Colors.white54)),
    );
  }

  Widget _buildActionOverlayBadge() {
    return Positioned(
      left: 8,
      top: 8,
      child: AnimatedOpacity(
        opacity: _overlayLabel != null ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(_overlayLabel ?? '',
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
      ),
    );
  }

  Widget _buildModeSwitcher() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SegmentedButton<ViewingMode>(
        segments: const [
          ButtonSegment(value: ViewingMode.snapshot, label: Text('Snapshot')),
          ButtonSegment(value: ViewingMode.live, label: Text('Watch Live')),
          ButtonSegment(value: ViewingMode.hybrid, label: Text('Hybrid')),
        ],
        selected: {_mode},
        onSelectionChanged: (s) => _setMode(s.first),
      ),
    );
  }
}

/// Live frame stream ko base64 JPEG se decode karke render karta hai —
/// dono thumbnail (`TaskMonitorScreen`) aur fullscreen view isi widget
/// ko reuse karte hain.
Widget _buildLiveFramePreview(Stream<dynamic>? frames) {
  if (frames == null) {
    return const Text('Live stream preview', style: TextStyle(color: Colors.white54));
  }
  return StreamBuilder<dynamic>(
    stream: frames,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white54),
            SizedBox(height: 8),
            Text('Connecting to live stream...', style: TextStyle(color: Colors.white54)),
          ],
        );
      }
      if (snapshot.hasError) {
        return const Text('Live stream error', style: TextStyle(color: Colors.redAccent));
      }
      final raw = snapshot.data;
      if (raw is! String && raw is! List<int>) {
        return const Text('Waiting for first frame...', style: TextStyle(color: Colors.white54));
      }
      try {
        final bytes = raw is String
            ? base64Decode(raw)
            : (raw is Uint8List ? raw : Uint8List.fromList(raw as List<int>));
        // `gaplessPlayback` — naya frame load hote waqt purana frame
        // gayab (blank flash) nahi hota, seedha replace hota hai —
        // continuous video jaisa feel dene ke liye zaroori hai.
        return Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true);
      } catch (_) {
        return const Text('Frame decode error', style: TextStyle(color: Colors.redAccent));
      }
    },
  );
}

/// Fullscreen live preview — thumbnail par tap karne se khulta hai.
class _FullscreenLivePreview extends StatelessWidget {
  final Stream<dynamic>? frames;
  const _FullscreenLivePreview({required this.frames});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(child: _buildLiveFramePreview(frames)),
    );
  }
}
