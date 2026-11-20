import 'dart:convert';
import 'dart:io';

import '../models/activity.dart';
import '../models/api_key.dart';
import '../models/device.dart';
import '../models/task.dart';
import '../connectors/connector_models.dart';
import '../util/crypto_utils.dart';
import 'app_state.dart';

/// Simple JSON-file persistence — **jaan-bujh kar SQLite/Postgres nahi
/// use kiya** kyunki:
///  1. Is project ke scale ke liye (ek user ke devices) yeh kaafi hai.
///  2. Koi native dependency (sqlite3 native lib) nahi chahiye — Docker
///     build simple aur reliable rehta hai.
///  3. Is sandbox mein Dart SDK khud available nahi thi (README mein
///     already note hai), isliye jitna simple rakh sakoon utna behtar —
///     kam moving parts, kam jagah bug chhup sakti hai.
///
/// **Railway par persistence ke liye Volume attach karna zaroori hai**
/// (neeche `dataDirectory()` ka comment dekho) — warna yeh file bhi
/// container restart par delete ho jaayegi, jaisa in-memory data hota.
class Persistence {
  final AppState state;
  final File _file;

  /// `fileOverride` — sirf tests ke liye (temp file inject karne ke
  /// liye, taaki `DATA_DIR` env var chhede bina persistence ka poora
  /// save/load round-trip test ho sake). Normal use mein hamesha
  /// `dataDirectory()`/`DATA_DIR` se hi path aata hai.
  bool _loadFailed = false;
  bool _blockSave = false;

  /// `true` agar state file load hi nahi ho saki (corrupt).
  bool get loadFailed => _loadFailed;

  /// `true` agar save() abhi block hai (backup nahi ban saka, original
  /// file ko overwrite hone se bachane ke liye).
  bool get saveBlocked => _blockSave;

  Future<void> _tail = Future<void>.value();
  Future<void>? _queued;

  Persistence(this.state, {File? fileOverride})
      : _file = fileOverride ?? File('${dataDirectory()}/state.json');

  /// `DATA_DIR` environment variable se path leta hai (default `/data`).
  /// **Railway setup:** apne service mein ek Volume attach karo, mount
  /// path `/data` do — us Volume ka content hi restarts ke beech survive
  /// karta hai. Volume attach kiye bina, `/data` container ke andar hi
  /// ek normal (ephemeral) folder hoga aur restart par sab kuch phir se
  /// khatam ho jaayega — matlab yeh code sahi hai, lekin Railway
  /// dashboard mein Volume attach karna ek zaroori extra step hai.
  static String dataDirectory() =>
      Platform.environment['DATA_DIR'] ?? '/data';

  /// Items 41/42/43: robust load.
  ///  * **Record-by-record** parse — ek bad record poori state ko adhoora
  ///    nahi chhodta; woh skip hota hai aur baaki load hote hain.
  ///  * Agar kuch bhi skip hua ya poori file corrupt thi, original file ka
  ///    **backup** (`state.json.corrupt-<ts>` / `.partial-<ts>`) bana
  ///    liya jata hai — agle `save()` se data permanently nahi jata.
  ///  * Backup bhi na bane to `save()` block rehta hai (original file
  ///    overwrite nahi hoti).
  ///  * Load ke baad `sessionToDevice` tasks se rebuild hota hai (42) aur
  ///    saare devices `OFFLINE` mark hote hain jab tak woh reconnect na
  ///    karein (43).
  Future<void> load() async {
    if (!await _file.exists()) return;

    final Map<String, dynamic> json;
    try {
      final raw = await _file.readAsString();
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      // ignore: avoid_print
      print('Persistence: state file unreadable/corrupt ($e)');
      _loadFailed = true;
      final ok = await _backupFile('corrupt');
      if (!ok) _blockSave = true;
      return;
    }

    var skipped = 0;
    void each(String key, void Function(Map<String, dynamic> m) parse) {
      for (final item in (json[key] as List<dynamic>? ?? const [])) {
        try {
          parse(item as Map<String, dynamic>);
        } catch (e) {
          skipped++;
          // ignore: avoid_print
          print('Persistence: skipped bad "$key" record ($e)');
        }
      }
    }

    each('devices', (m) {
      state.devices[m['id'] as String] = Device(
        id: m['id'] as String,
        name: m['name'] as String,
        // P0-06 migration: purane persisted files mein plaintext
        // `bearer_token` hota tha, naye mein sirf `bearer_token_hash`.
        bearerTokenHash: (m['bearer_token_hash'] as String?) ??
            hashSecretUtil(m['bearer_token'] as String),
        // P1-02 migration: purane devices mein platform nahi hota.
        platform: m['platform'] as String? ?? 'unknown',
        pairedAt: DateTime.parse(m['paired_at'] as String),
        lastSeenAt: DateTime.parse(m['last_seen_at'] as String),
        state: m['state'] as String? ?? 'OFFLINE',
        backgroundActive: m['background_active'] as bool? ?? false,
        batteryPercent: m['battery_percent'] as int?,
        lastLocation: m['last_location'] as Map<String, dynamic>?,
        lastNetwork: m['last_network'] as Map<String, dynamic>?,
      );
    });

    each('api_keys', (m) {
      state.apiKeys[m['key_id'] as String] = ApiKeyRecord(
        keyId: m['key_id'] as String,
        deviceId: m['device_id'] as String,
        label: m['label'] as String,
        scope: ApiKeyScope.fromJson(m['scope'] as Map<String, dynamic>),
        createdAt: DateTime.parse(m['created_at'] as String),
        secretHash: m['secret_hash'] as String,
        enabled: m['enabled'] as bool? ?? true,
        // Item 21 — purani files mein yeh fields nahi hongi.
        expiresAt: m['expires_at'] == null
            ? null
            : DateTime.parse(m['expires_at'] as String),
        lastUsedAt: m['last_used_at'] == null
            ? null
            : DateTime.parse(m['last_used_at'] as String),
      );
    });

    each('activity_log', (m) {
      state.activityLog.add(ActivityEvent(
        eventType: m['event_type'] as String,
        deviceId: m['device_id'] as String,
        source: m['source'] as String?,
        taskId: m['task_id'] as String?,
        timestamp: DateTime.parse(m['timestamp'] as String),
        status: m['status'] as String,
        actor: m['actor'] as String,
        category: m['category'] as String?,
      ));
    });

    // P0-07 — connector credentials (sirf **encrypted** values).
    each('connector_credentials', (m) {
      state.storeConnectorCredential(ConnectorCredential(
        deviceId: m['device_id'] as String,
        connectorName: m['connector_name'] as String,
        encryptedAccessToken: m['encrypted_access_token'] as String,
        encryptedRefreshToken: m['encrypted_refresh_token'] as String?,
        accessTokenExpiresAt:
            DateTime.parse(m['access_token_expires_at'] as String),
        grantedScopes: (m['granted_scopes'] as List<dynamic>? ?? []).cast<String>(),
        connectedAt: DateTime.parse(m['connected_at'] as String),
      ));
    });

    // P1-01 — persistent custom capability manifests (already validated).
    each('custom_capability_manifests', (m) {
      state.customCapabilityManifests.add(m);
    });

    // Task lifecycle state (including lastCheckpoint).
    each('tasks', (m) {
      final taskId = m['task_id'] as String;
      state.tasks[taskId] = TaskRecord(
        taskId: taskId,
        deviceId: m['device_id'] as String,
        originatingCapability: m['capability'] as String,
        state: taskStateFromWire(m['state'] as String?) ?? TaskState.stopped,
        createdAt: DateTime.parse(m['created_at'] as String),
        updatedAt: DateTime.parse(m['updated_at'] as String),
        lastCheckpoint: m['checkpoint'] as Map<String, dynamic>?,
      )..terminalReason = m['reason'] as String?;
    });

    // Item 42: restart ke baad `/sessions/{id}` aur `/screen/{id}` 404 na
    // dein — session ownership tasks se wapas banao.
    for (final t in state.tasks.values) {
      state.sessionToDevice[t.taskId] = t.deviceId;
    }

    // Item 43: restart ke baad koi device-WS connected nahi hota, to
    // persisted "ONLINE_*" state stale hai. Device reconnect par khud
    // sahi state report karega.
    for (final d in state.devices.values) {
      d.state = 'OFFLINE';
    }

    if (skipped > 0) {
      // Kuch records parse nahi hue — original ko backup karo, warna agla
      // save() unhe hamesha ke liye hata dega.
      final ok = await _backupFile('partial');
      if (!ok) _blockSave = true;
    }

    // ignore: avoid_print
    print('Persistence: loaded ${state.devices.length} devices, '
        '${state.apiKeys.length} keys, ${state.activityLog.length} '
        'activity events, ${state.connectorCredentials.length} connector '
        'credentials, ${state.customCapabilityManifests.length} custom '
        'capability manifests, ${state.tasks.length} tasks from ${_file.path}'
        '${skipped > 0 ? ' ($skipped bad records skipped, backup saved)' : ''}');
  }

  Future<bool> _backupFile(String tag) async {
    try {
      final ts = DateTime.now().toUtc().millisecondsSinceEpoch;
      await _file.copy('${_file.path}.$tag-$ts');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('Persistence: backup failed ($e) — save blocked to protect original');
      return false;
    }
  }

  /// Item 40: saves ab **serialize + coalesce** hote hain. Pehle timer aur
  /// har mutation ke saath save() concurrently chalti thi aur sab ek hi
  /// `.tmp` file par likhte the (corrupt file / rename fail). Ab ek
  /// waqt par ek hi write chalti hai; jab write chal rahi ho to naye
  /// requests ek hi agli write mein merge ho jaate hain.
  Future<void> save() {
    if (_blockSave) return Future<void>.value();
    final queued = _queued;
    if (queued != null) return queued;
    final f = _tail.then((_) {
      _queued = null;
      return _saveOnce();
    });
    _queued = f;
    _tail = f.catchError((_) {});
    return f;
  }

  Future<void> _saveOnce() async {
    try {
      await _file.parent.create(recursive: true);

      final json = {
        'devices': state.devices.values
            .map((d) => {
                  'id': d.id,
                  'name': d.name,
                  'bearer_token_hash': d.bearerTokenHash,
                  'platform': d.platform,
                  'paired_at': d.pairedAt.toIso8601String(),
                  'last_seen_at': d.lastSeenAt.toIso8601String(),
                  'state': d.state,
                  'background_active': d.backgroundActive,
                  'battery_percent': d.batteryPercent,
                  'last_location': d.lastLocation,
                  'last_network': d.lastNetwork,
                })
            .toList(),
        'api_keys': state.apiKeys.values
            .map((k) => {
                  'key_id': k.keyId,
                  'device_id': k.deviceId,
                  'label': k.label,
                  'scope': k.scope.toJson(),
                  'created_at': k.createdAt.toIso8601String(),
                  'secret_hash': k.secretHash,
                  'enabled': k.enabled,
                  if (k.expiresAt != null)
                    'expires_at': k.expiresAt!.toUtc().toIso8601String(),
                  if (k.lastUsedAt != null)
                    'last_used_at': k.lastUsedAt!.toUtc().toIso8601String(),
                })
            .toList(),
        // Activity log — sirf last 2000 events persist karte hain (poora
        // in-memory bound already 5000 hai, disk par thoda tighter rakha
        // taaki file zyada bada na ho).
        'activity_log': state.activityLog
            .skip(state.activityLog.length > 2000 ? state.activityLog.length - 2000 : 0)
            .map((e) => e.toJson())
            .toList(),
        // P0-07 — connector credentials, **encrypted values hi** (kabhi
        // plaintext nahi) — `credential_encryption.dart` se already
        // encrypted aati hain, yahan sirf as-is serialize ho rahi hain.
        'connector_credentials': state.connectorCredentials.values
            .map((c) => {
                  'device_id': c.deviceId,
                  'connector_name': c.connectorName,
                  'encrypted_access_token': c.encryptedAccessToken,
                  'encrypted_refresh_token': c.encryptedRefreshToken,
                  'access_token_expires_at': c.accessTokenExpiresAt.toIso8601String(),
                  'granted_scopes': c.grantedScopes,
                  'connected_at': c.connectedAt.toIso8601String(),
                })
            .toList(),
        // P1-01 — custom capability manifests.
        'custom_capability_manifests': state.customCapabilityManifests,
        // Audit fix (Section 8 / Section 13 #2) — task lifecycle state
        // (including lastCheckpoint) ab persist hoti hai (dekhein load()
        // ka comment).
        'tasks': state.tasks.values.map((t) => t.toJson()).toList(),
      };

      // Atomic write — pehle temp file, phir rename. Isse agar save ke
      // beech mein process crash ho jaaye, purani file corrupt nahi
      // hoti (naya write ya poora hota hai ya bilkul nahi).
      final tempFile =
          File('${_file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}');
      await tempFile.writeAsString(jsonEncode(json));

      // DEP-01 — safe file permissions: owner-only read/write (0600).
      // File mein encrypted connector tokens aur hashes hain (kabhi
      // plaintext secret nahi — P0-06/P0-07), lekin defense-in-depth
      // ke tor par bhi is file ko world-readable chhodna koi wajah nahi
      // hai. POSIX-only (`chmod` Windows par kuch aur maayne rakhta
      // hai — Windows par yeh silently ignore ho jaata hai, koi crash
      // nahi).
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', ['600', tempFile.path]);
        } catch (_) {
          // chmod na chal paaye (kuch minimal containers mein nahi
          // hota) — save khud fail nahi honi chahiye is wajah se.
        }
      }

      await tempFile.rename(_file.path);
    } catch (e) {
      // Orphan tmp files saaf karo (best effort).
      try {
        for (final f in _file.parent.listSync()) {
          if (f is File && f.path.startsWith('${_file.path}.tmp.')) {
            f.deleteSync();
          }
        }
      } catch (_) {}
      // Save fail hona should crash na kare request handling — sirf log.
      // ignore: avoid_print
      print('Persistence: save failed: $e');
    }
  }

  /// DEP-01 — startup health check: DATA_DIR mein likh sakte hain ya
  /// nahi, yeh turant pata chal jaana chahiye (server start hote hi),
  /// na ke pehle real save() call fail hone par kisi request ke beech
  /// mein. Read-only filesystem, missing permissions, waghera turant
  /// pakde jaate hain.
  ///
  /// Return `true` = likh sakte hain. `false` = nahi likh sakte — caller
  /// (`bin/server.dart`) is case mein ek loud, unmissable warning print
  /// karta hai (server phir bhi start hota hai — read-only mode mein
  /// chalna, crash hone se behtar hai — lekin operator ko turant pata
  /// chal jaana chahiye).
  Future<bool> verifyWritable() async {
    try {
      await _file.parent.create(recursive: true);
      final probe = File('${_file.parent.path}/.write_probe');
      await probe.writeAsString(DateTime.now().toIso8601String());
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }
}
