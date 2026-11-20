/// P0-03 — Production HTTPS/WSS Transport (client side).
///
/// Pehle `shared_app/lib/main.dart` mein control API ka URL seedha
/// source code mein hardcoded tha (`Uri.parse('http://localhost:8080')`)
/// aur build karne se pehle manually edit karna padta tha. Audit ke
/// mutabiq: "Production API URL environment/configuration se aaye...
/// Localhost sirf development mode mein allowed ho... API URL ko
/// hardcode se hata kar safe configuration banao."
///
/// Ab yeh compile-time `--dart-define=CONTROL_API_URL=...` se aata hai
/// (default localhost:8080, sirf debug/dev convenience ke liye).
library;

import 'package:flutter/foundation.dart' show kDebugMode;

/// Thrown jab configuration khud hi unsafe ho (e.g. release build mein
/// plaintext http kisi non-localhost host ke liye) — startup par hi
/// fail-fast, taaki galti se production mein credentials/commands
/// plaintext na chale jaayein.
class InsecureTransportConfigError extends Error {
  final String message;
  InsecureTransportConfigError(this.message);
  @override
  String toString() => 'InsecureTransportConfigError: $message';
}

class AppConfig {
  /// REST/HTTP base URL — saari API calls (`DeviceAgentApiClient`) isi
  /// se resolve hoti hain.
  final Uri controlApiBaseUrl;

  /// WS/WSS base URL — `AgentConnection`, `SessionEventChannel`,
  /// `LiveScreenChannel` sab isi se apna path resolve karte hain.
  /// `controlApiBaseUrl` se automatically derive hota hai (http->ws,
  /// https->wss) — kahin bhi manually scheme convert karne ki zaroorat
  /// nahi, is liye galti se mismatch (jaise https base URL ko seedha
  /// `WebSocket.connect` mein pass kar dena, jo fail hota hai) ab
  /// possible hi nahi.
  final Uri controlApiWsBaseUrl;

  AppConfig._(this.controlApiBaseUrl, this.controlApiWsBaseUrl);

  /// `--dart-define=CONTROL_API_URL=https://...` se load karta hai.
  /// Thin wrapper around [resolve] — asal logic testable rakhne ke liye
  /// alag nikala gaya hai (compile-time `String.fromEnvironment` khud
  /// unit test mein parameterize nahi ho sakta).
  factory AppConfig.load() {
    const rawUrl = String.fromEnvironment(
      'CONTROL_API_URL',
      defaultValue: 'http://localhost:8080',
    );
    return AppConfig.resolve(rawUrl, debugMode: kDebugMode);
  }

  /// Core resolution logic — pure function, `kDebugMode`/`--dart-define`
  /// par depend nahi karta, is liye tests isko directly alag-alag inputs
  /// ke saath call kar sakte hain.
  ///
  /// Fail-fast checks (acceptance criteria: "Production build plaintext
  /// HTTP/WS reject kare; development localhost allowed"):
  ///   - Agar yeh ek release/profile build hai (`debugMode == false`) aur
  ///     configured host localhost/127.0.0.1/::1 nahi hai, to scheme
  ///     zaroor `https` honi chahiye — warna `InsecureTransportConfigError`.
  ///   - Debug build mein localhost par http allowed hai (normal dev
  ///     loop: control_api local chal raha ho).
  static AppConfig resolve(String rawUrl, {required bool debugMode}) {
    final httpUri = Uri.parse(rawUrl);

    final isLoopback = httpUri.host == 'localhost' ||
        httpUri.host == '127.0.0.1' ||
        httpUri.host == '::1';

    if (!debugMode && !isLoopback && httpUri.scheme != 'https') {
      throw InsecureTransportConfigError(
        'CONTROL_API_URL ("$rawUrl") release build mein plaintext HTTP '
        'ke saath non-localhost host allowed nahi hai. HTTPS use karein '
        '(e.g. https://your-app.up.railway.app) — build command: '
        '`flutter build <target> --dart-define=CONTROL_API_URL=https://...`',
      );
    }
    // localhost par bhi agar koi https use karna chahe to koi harj nahi
    // (self-signed local dev TLS jaise setups ke liye) — sirf http ko
    // reject nahi karte localhost par.

    final wsScheme = httpUri.scheme == 'https' ? 'wss' : 'ws';
    final wsUri = httpUri.replace(scheme: wsScheme);

    return AppConfig._(httpUri, wsUri);
  }
}
