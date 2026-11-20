/// P1-08 — Data Channel Hardening — Upload/Download/File Security.
///
/// Audit: "Native Android/Linux/Windows path traversal protection
/// exists" (device-side, real filesystem-root enforcement — sirf woh
/// device apne actual filesystem ke against kar sakta hai) — "lekin
/// server-side scoped authorization, file-size limits, MIME/type
/// validation... remain." Yeh file wahi **server-side, defense-in-depth**
/// layer hai — device tak koi obviously malicious path/oversized/
/// dangerous-type payload kabhi forward hi nahi hone dete.
///
/// **Scope boundary (honest)**: server ke paas device ka real filesystem
/// nahi hai, is liye yeh sirf **pattern-level** checks kar sakta hai
/// (traversal sequences, extension allowlist/blocklist, size) — asal
/// "allowed root" enforcement (jaise "sirf /sdcard/Download ke andar")
/// device-side hi ho sakta hai (jo audit ke mutabiq already maujood
/// hai). Yeh dono layers saath mein defense-in-depth banate hain.
library;

import 'dart:convert';

class PathValidationResult {
  final bool isValid;
  final String? error;
  const PathValidationResult._(this.isValid, this.error);
  factory PathValidationResult.valid() => const PathValidationResult._(true, null);
  factory PathValidationResult.invalid(String error) => PathValidationResult._(false, error);
}

/// DATA-01 acceptance: "traversal rejected". `..` kisi bhi form mein
/// (`../`, `..\`, URL-encoded `%2e%2e` already P0-04 ke JSON string
/// decode ke baad plain `..` ban chuki hoti hai) — substring check hi
/// kaafi hai, encoding tricks JSON parse ke baad automatically resolve
/// ho chuki hoti hain.
PathValidationResult validateFilePath(String path) {
  if (path.isEmpty) {
    return PathValidationResult.invalid('Path khaali nahi ho sakta');
  }
  // Sirf poore segment `..` ko block karte hain (`a..b.txt` jaisa
  // legit filename galti se block na ho).
  if (path.split(RegExp(r'[\\/]')).any((seg) => seg.trim() == '..')) {
    return PathValidationResult.invalid(
        'Path mein ".." (parent-directory traversal) allowed nahi hai');
  }
  if (path.contains('\u0000')) {
    return PathValidationResult.invalid('Path mein null byte allowed nahi hai');
  }
  if (path.length > 4096) {
    return PathValidationResult.invalid('Path 4096 characters se zyada lamba hai');
  }
  return PathValidationResult.valid();
}

/// `files.write`/`data.upload` ke liye alag, zyada generous size limit —
/// `validation/schema_validator.dart`'s general `maxRequestBodyBytes`
/// (2 MiB, saari commands ke liye) is se chhota hai, file transfers ke
/// liye woh limit bohot tight hai. Yeh limit specifically inhi
/// payload-carrying actions par lagta hai.
const maxUploadPayloadBytes = 10 * 1024 * 1024; // 10 MiB

/// `payload` field base64 string hai — decode kiye bina hi uski
/// approximate decoded size nikal lete hain (base64 ~4/3x overhead —
/// exact decode se pehle hi reject karna sasta hai, especially bade
/// malicious payloads ke liye).
class PayloadSizeResult {
  final bool isValid;
  final String? error;
  final int? decodedByteLength;
  const PayloadSizeResult._(this.isValid, this.error, this.decodedByteLength);
  factory PayloadSizeResult.valid(int decodedByteLength) =>
      PayloadSizeResult._(true, null, decodedByteLength);
  factory PayloadSizeResult.invalid(String error) => PayloadSizeResult._(false, error, null);
}

PayloadSizeResult validateUploadPayloadSize(String? base64Payload) {
  if (base64Payload == null || base64Payload.isEmpty) {
    return PayloadSizeResult.invalid(
        'Is action ke liye "payload" (base64 file content) required hai');
  }
  // Base64 decoded size ≈ base64Length * 3/4 (padding ignore karte hue,
  // yeh estimate hamesha thoda upar hi hota hai, jo safe direction hai).
  final estimatedBytes = (base64Payload.length * 3) ~/ 4;
  if (estimatedBytes > maxUploadPayloadBytes) {
    return PayloadSizeResult.invalid(
        'Payload $maxUploadPayloadBytes bytes (~${maxUploadPayloadBytes ~/ (1024 * 1024)} MiB) '
        'se zyada hai — SEC-02: oversized upload dispatch se pehle hi reject');
  }
  // Estimate ke baad bhi actual decode zaroori hai — malformed base64
  // bhi yahin pakad lete hain (device tak corrupt payload forward nahi
  // hoti).
  try {
    final bytes = base64.decode(base64Payload);
    if (bytes.length > maxUploadPayloadBytes) {
      return PayloadSizeResult.invalid(
          'Payload $maxUploadPayloadBytes bytes se zyada hai (decoded: ${bytes.length})');
    }
    return PayloadSizeResult.valid(bytes.length);
  } on FormatException {
    return PayloadSizeResult.invalid('"payload" valid base64 nahi hai');
  }
}

/// Blocklist (allowlist nahi — yeh tool jaan-bujh kar general-purpose
/// hai, users apni arbitrary files transfer karna chahte hain, is liye
/// ek strict allowlist bohot restrictive hoti). Sirf genuinely
/// dangerous-to-execute types block karte hain — self-propagating
/// malware/executable payloads ka sabse aam vector.
const _dangerousExtensions = {
  '.exe', '.msi', '.msix', '.appx', '.bat', '.cmd', '.com', '.scr', '.pif', // Windows executables
  '.ps1', '.psm1', '.vbs', '.vbe', '.wsf', '.wsh', '.hta', '.js', '.jse', // Windows scripts
  '.lnk', '.reg', '.cpl', '.msc', '.gadget', '.inf', // shortcuts / registry / control panel
  '.sh', '.bash', '.zsh', '.run', '.bin', '.py', '.pl', '.rb', // Unix/Linux scripts
  '.desktop', '.appimage', '.deb', '.rpm', // Linux launchers / installers
  '.apk', '.aab', '.dex', // Android installer / code
  '.dll', '.so', '.dylib', '.sys', // native libraries / drivers
  '.jar', // Java executable
};

/// Item 14: filename ko normalize karo taaki common bypass tricks kaam
/// na karein:
///  * case (`MALWARE.EXE`),
///  * trailing dots/spaces jo Windows chup-chap hata deta hai
///    (`payload.exe.`, `payload.exe `),
///  * NTFS Alternate Data Stream (`payload.exe:hidden`, `a.txt:evil.exe`).
/// Sirf **last path segment** dekhte hain.
String normalizeFileNameForPolicy(String path) {
  var name = path.split(RegExp(r'[\\/]')).last;
  // ADS: `name:stream[:$DATA]` — asli file name pehle colon se pehle hai,
  // lekin stream part mein bhi executable extension ho sakti hai, isliye
  // dono parts alag-alag check hote hain (dekhein neeche).
  name = name.toLowerCase();
  return name;
}

PathValidationResult validateUploadFileType(String path) {
  final name = normalizeFileNameForPolicy(path);
  // ADS ke har part ko alag check karo.
  final parts = name.split(':');
  for (final raw in parts) {
    // Windows trailing dots/spaces ignore karta hai.
    final part = raw.replaceAll(RegExp(r'[. ]+$'), '');
    for (final ext in _dangerousExtensions) {
      if (part.endsWith(ext)) {
        return PathValidationResult.invalid(
            'File type "$ext" security reasons se upload allowed nahi hai '
            '(executable/installer/script types blocked)');
      }
    }
  }
  return PathValidationResult.valid();
}

/// Item 13: `browser.navigate` (aur koi bhi URL-opening action) sirf
/// `http`/`https` allow karta hai. `file://`, `javascript:`, `data:`,
/// `intent:`, `content:`, `tel:` jaisi schemes local files padhne ya
/// device par arbitrary actions trigger karne ke kaam aa sakti hain.
PathValidationResult validateBrowserUrl(String? url) {
  if (url == null || url.trim().isEmpty) {
    return PathValidationResult.invalid('"url" required hai');
  }
  if (url.length > 8192) {
    return PathValidationResult.invalid('URL 8192 characters se zyada lamba hai');
  }
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme) {
    return PathValidationResult.invalid('URL mein scheme (http/https) hona chahiye');
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    return PathValidationResult.invalid(
        'URL scheme "$scheme" allowed nahi hai — sirf http/https');
  }
  if (uri.host.isEmpty) {
    return PathValidationResult.invalid('URL mein host hona chahiye');
  }
  return PathValidationResult.valid();
}
