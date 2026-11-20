/// Items 32/33/52: device ka poora status (lock state, battery, network,
/// location, background-active) server ko bhejta hai —
///  * har successful (re)connect par (item 33),
///  * lock/sleep state badalne par,
///  * periodically (default har 5 min; location har 3rd tick par).
///
/// Pehle sirf lock-state *badalne par* jaata tha; battery/network/
/// location kabhi report nahi hote the, isliye Device Status screen par
/// "Battery --" aur "Location Unavailable" hi rehta tha.
///
/// Privacy: location sirf tab jati hai jab user ne setup mein local
/// policy mein Location allow kiya ho ([locationAllowed]).
library;

import 'dart:async';

typedef StatusSender = void Function({
  String? state,
  int? batteryPercent,
  bool? backgroundActive,
  Map<String, dynamic>? network,
  Map<String, dynamic>? location,
});

class StatusReporter {
  final StatusSender send;
  final Future<String?> Function() readLockState;
  final Future<int?> Function() readBattery;
  final Future<Map<String, dynamic>?> Function() readNetwork;
  final Future<Map<String, dynamic>?> Function() readLocation;
  final bool Function() locationAllowed;
  final Duration interval;

  Timer? _timer;
  int _tick = 0;

  StatusReporter({
    required this.send,
    required this.readLockState,
    required this.readBattery,
    required this.readNetwork,
    required this.readLocation,
    required this.locationAllowed,
    this.interval = const Duration(minutes: 5),
  });

  /// Ek full snapshot bhejo. Har reader independently fail ho sakta hai
  /// (permission/native bridge missing) — fail hone wala field bas skip
  /// hota hai, baaki jaate hain.
  Future<void> reportNow({bool includeLocation = false}) async {
    final state = await _safe(readLockState);
    final battery = await _safe(readBattery);
    final network = await _safe(readNetwork);
    Map<String, dynamic>? location;
    if (includeLocation && locationAllowed()) {
      location = await _safe(readLocation);
    }
    send(
      state: state,
      batteryPercent: battery,
      backgroundActive: true,
      network: network,
      location: location,
    );
  }

  void start() {
    _timer?.cancel();
    _tick = 0;
    _timer = Timer.periodic(interval, (_) {
      _tick++;
      unawaited(reportNow(includeLocation: _tick % 3 == 0));
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<T?> _safe<T>(Future<T?> Function() fn) async {
    try {
      return await fn();
    } catch (_) {
      return null;
    }
  }
}
