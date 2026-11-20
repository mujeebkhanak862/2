/// Item 24: device credentials (id + bearer token) aur local permission
/// policy ko app restart ke baad bhi yaad rakhna.
///
/// Pehle `deviceId`/`bearerToken` sirf memory mein the, isliye har
/// restart par naya device ban jata tha aur purani API keys bekaar ho
/// jati thi. Ab OS ki secure storage (Android Keystore, Windows DPAPI /
/// Credential Locker, Linux libsecret) mein save hote hain.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../protocol/api_key.dart';

class StoredCredentials {
  final String deviceId;
  final String bearerToken;
  const StoredCredentials({required this.deviceId, required this.bearerToken});
}

abstract class CredentialStore {
  Future<StoredCredentials?> loadCredentials();
  Future<void> saveCredentials(StoredCredentials credentials);

  /// Setup wizard mein user ne jo permissions chuni (device-local
  /// "ceiling" policy). `null` matlab setup abhi hua hi nahi.
  Future<ApiKeyScope?> loadPolicy();
  Future<void> savePolicy(ApiKeyScope scope);

  /// Unpair / 401 par sab kuch hata do.
  Future<void> clear();
}

const _kDeviceId = 'uda.device_id';
const _kToken = 'uda.bearer_token';
const _kPolicy = 'uda.local_policy';

/// Production implementation — `flutter_secure_storage`.
class SecureCredentialStore implements CredentialStore {
  final FlutterSecureStorage _storage;
  SecureCredentialStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<StoredCredentials?> loadCredentials() async {
    try {
      final id = await _storage.read(key: _kDeviceId);
      final token = await _storage.read(key: _kToken);
      if (id == null || token == null || id.isEmpty || token.isEmpty) {
        return null;
      }
      return StoredCredentials(deviceId: id, bearerToken: token);
    } catch (_) {
      // Storage unavailable (jaise Linux par libsecret nahi) — "kuch
      // saved nahi" maan lo; app naye pairing se chalega.
      return null;
    }
  }

  @override
  Future<void> saveCredentials(StoredCredentials credentials) async {
    await _storage.write(key: _kDeviceId, value: credentials.deviceId);
    await _storage.write(key: _kToken, value: credentials.bearerToken);
  }

  @override
  Future<ApiKeyScope?> loadPolicy() async {
    try {
      final raw = await _storage.read(key: _kPolicy);
      if (raw == null || raw.isEmpty) return null;
      return ApiKeyScope.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> savePolicy(ApiKeyScope scope) =>
      _storage.write(key: _kPolicy, value: jsonEncode(scope.toJson()));

  @override
  Future<void> clear() async {
    await _storage.delete(key: _kDeviceId);
    await _storage.delete(key: _kToken);
    await _storage.delete(key: _kPolicy);
  }
}

/// Tests aur storage-less fallback ke liye.
class InMemoryCredentialStore implements CredentialStore {
  StoredCredentials? _credentials;
  ApiKeyScope? _policy;

  @override
  Future<StoredCredentials?> loadCredentials() async => _credentials;

  @override
  Future<void> saveCredentials(StoredCredentials credentials) async =>
      _credentials = credentials;

  @override
  Future<ApiKeyScope?> loadPolicy() async => _policy;

  @override
  Future<void> savePolicy(ApiKeyScope scope) async => _policy = scope;

  @override
  Future<void> clear() async {
    _credentials = null;
    _policy = null;
  }
}
