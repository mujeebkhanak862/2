/// Item 22: `Map` jo har structural mutation (add / replace / remove /
/// clear) par ek `version` counter badhata hai. `AppState` isse hash-
/// index (secret-hash -> id) ko lazily rebuild karta hai — taaki
/// lookup O(1) rahe, aur jo code (ya tests) seedha `state.devices[id] = ...`
/// likhte hain unke liye index kabhi stale na rahe.
///
/// Note: record ke andar ka in-place field change (jaise
/// `device.bearerTokenHash = ...`) map-level mutation nahi hai — us
/// case mein caller ko `touch()` call karna hota hai.
library;

import 'dart:collection';

class VersionedMap<V> extends MapBase<String, V> {
  final Map<String, V> _inner = {};
  int _version = 0;

  /// Har mutation par badhta hai.
  int get version => _version;

  /// In-place record change ke baad index invalidate karne ke liye.
  void touch() => _version++;

  @override
  V? operator [](Object? key) => _inner[key];

  @override
  void operator []=(String key, V value) {
    _inner[key] = value;
    _version++;
  }

  @override
  void clear() {
    _inner.clear();
    _version++;
  }

  @override
  Iterable<String> get keys => _inner.keys;

  @override
  V? remove(Object? key) {
    final had = _inner.containsKey(key);
    final removed = _inner.remove(key);
    if (had) _version++;
    return removed;
  }
}
