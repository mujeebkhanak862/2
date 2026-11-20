/// P0-04 — Strict Request + Schema Validation.
///
/// Yeh file `POST /commands` ke liye ek canonical validator layer hai.
/// Pehle yahan sirf teen top-level fields (`request_id`, `capability`,
/// `action`) ki *presence* check hoti thi — type safety nahi thi (agar
/// koi field galat type ka hota, jaise `"request_id": 123`, to seedha
/// Dart type-cast exception throw hoti, jo shelf ka generic 500 error
/// banati — koi deterministic 4xx nahi). Malformed JSON bhi crash karta
/// tha. Params ke andar bhi koi schema check nahi thi — koi bhi action
/// kisi bhi (ya khaali) params ke saath device tak chali jaati thi.
///
/// Ab yeh validator:
///   1. Malformed JSON ko cleanly INVALID_REQUEST (400) mein badalta hai.
///   2. Har top-level field ka *type* check karta hai (na sirf presence).
///   3. `capability` + `action` ko `models/capabilities.dart` ki
///      `builtInCapabilityManifests()` (single source of truth) se
///      cross-verify karta hai — unknown action turant reject.
///   4. Action ke `params_schema` (ab real hai, capabilities.dart mein
///      defined) se `params` validate karta hai — required fields,
///      types, length/range bounds, aur (jab tak schema explicitly
///      `additionalProperties: true` na kahe) unknown params fields
///      bhi reject karta hai.
///   5. `payload` (base64) aur `timeout_ms` ke bounds check karta hai.
///
/// **Unknown-field policy** (audit: "Unknown action/field policy define
/// karein"): asymmetric hai, jaan-bujh kar —
///   - Top-level envelope fields: unknown fields **tolerate** hote hain
///     (PROTOCOL_V1.md khud kehta hai: "naye fields sirf add ho sakte
///     hain... purana client naye server ke saath chal sake" — forward
///     compatibility ka core guarantee hai).
///   - `params` ke andar, per-action: unknown fields **reject** hote
///     hain by default (`additionalProperties: false` implicit) — yeh
///     forward-compat guarantee params par apply nahi hoti (params
///     action-specific hain, naya client purane server se baat nahi kar
///     raha in mein), aur strict rehna typo/misuse jaldi pakadta hai.
library;

import 'dart:convert';

import '../models/capabilities.dart';

/// Command envelope ke top-level bounds. `params`/`payload` alag se bhi
/// individually bound hote hain (neeche), yeh poore request body ka
/// upper limit hai.
///
/// NOTE: yeh ek general, sab actions ke liye uniform bound hai. Bade
/// file transfers (`data.upload`/`files.write`) ke liye dedicated,
/// zyada sochi-samjhi size/MIME limits **P1-08 (Data Channel
/// Hardening)** ka scope hain — yeh sirf ek interim safety floor hai
/// taaki koi bhi command endpoint ko unbounded payload se flood na kar
/// sake jab tak P1-08 nahi ban jaata.
const maxRequestBodyBytes = 2 * 1024 * 1024; // 2 MiB

/// Item 39: upload actions (`files.write`, `data.upload`) ke liye body
/// limit. Payload limit 10 MiB *decoded* hai => base64 ~13.3 MiB; 14 MiB
/// us par envelope overhead ke liye kaafi margin deta hai. Baaki sab
/// actions ke liye 2 MiB hi rehta hai. (Pehle sab ke liye 2 MiB tha,
/// isliye 10 MiB wali limit kabhi reach hi nahi hoti thi — asal limit
/// ~1.5 MB file thi.)
const maxUploadRequestBodyBytes = 14 * 1024 * 1024;

bool _isUploadAction(Object? action) =>
    action == 'files.write' || action == 'data.upload';

const maxTimeoutMs = 120000; // 2 minutes — sabse lamba koi bhi command wait karega
const minTimeoutMs = 1;

class ValidationError {
  final String message;
  /// `'PAYLOAD_TOO_LARGE'` ya `'INVALID_REQUEST'` — caller (commands.dart)
  /// isi se sahi HTTP status/error-code choose karta hai.
  final String kind;
  const ValidationError(this.message, {this.kind = 'INVALID_REQUEST'});
}

class EnvelopeValidationResult {
  final Map<String, dynamic>? envelope; // non-null iff valid
  final ValidationError? error; // non-null iff invalid

  const EnvelopeValidationResult.valid(Map<String, dynamic> this.envelope)
      : error = null;
  const EnvelopeValidationResult.invalid(ValidationError this.error)
      : envelope = null;

  bool get isValid => envelope != null;
}

/// Action-name -> {capability, params_schema} index. Built-in manifests
/// (`models/capabilities.dart`) **hamesha** shामil hote hain; `customManifests`
/// (P1-01 registry se, runtime par badal sakte hain — isi liye yeh
/// top-level `final` cache ke bajaye per-call parameter hai, module-load
/// snapshot nahi) is call ke waqt jo bhi registered custom capabilities
/// hain unhe merge karta hai.
///
/// **Audit-adjacent bug jo yahan mila (P1-02 se related, usse bhi gehra)**:
/// pehle yeh sirf `builtInCapabilityManifests()` se ek baar (module load
/// par) ban ke cache ho jaata tha — matlab koi bhi custom capability
/// action yahan **kabhi milta hi nahi tha** ("Unknown action" — turant
/// 400), chahe wo capability register ho chuki ho aur caller ki API key
/// ko uski explicit permission bhi di gayi ho (P1-02 fix). Validation
/// layer authorization layer se **pehle** chalti hai (`commands.dart`
/// mein), is liye P1-02 ka authorization fix khud bhi is validation gate
/// tak kabhi pahunch hi nahi paata tha — custom capabilities end-to-end
/// abhi bhi completely unusable rehti, sirf ek alag jagah (validation,
/// authorization ki bajaye) block hoti.
Map<String, ({String capability, Map<String, dynamic> schema})>? _builtInActionIndex;

Map<String, ({String capability, Map<String, dynamic> schema})> _buildBuiltInIndex() {
  final index = <String, ({String capability, Map<String, dynamic> schema})>{};
  for (final manifest in builtInCapabilityManifests()) {
    final capability = manifest['capability'] as String;
    final actions = manifest['actions'] as List<Map<String, dynamic>>;
    for (final action in actions) {
      final name = action['name'] as String;
      final schema = action['params_schema'] as Map<String, dynamic>? ?? const {};
      index[name] = (capability: capability, schema: schema);
    }
  }
  return index;
}

Map<String, ({String capability, Map<String, dynamic> schema})> _buildActionIndex(
    List<Map<String, dynamic>> customManifests) {
  // Item 51: built-in manifests process lifetime mein badalte nahi, isliye
  // unka index sirf ek baar banta hai (pehle har request par poora
  // `builtInCapabilityManifests()` dobara build hota tha).
  final index = Map<String, ({String capability, Map<String, dynamic> schema})>.of(
      _builtInActionIndex ??= _buildBuiltInIndex());
  for (final manifest in customManifests) {
    final capability = manifest['capability'] as String;
    final actions = (manifest['actions'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    for (final action in actions) {
      final name = action['name'] as String;
      final schema = action['params_schema'] as Map<String, dynamic>? ?? const {};
      // Built-in actions ko koi custom manifest override/shadow nahi kar
      // sakta — `validateCustomManifest` (P1-01) registration ke waqt
      // hi collision reject karta hai, lekin yahan bhi defense-in-depth
      // ke tor par built-in ko priority dete hain (pehle se `index[name]`
      // set ho to skip).
      index.putIfAbsent(name, () => (capability: capability, schema: schema));
    }
  }
  return index;
}

/// Raw HTTP request body (bytes, before JSON parsing) validate + parse
/// karta hai. Yeh sabse pehla gate hai — `bodyByteLength` se hi payload
/// size reject ho jaati hai bina poora JSON parse kiye.
EnvelopeValidationResult validateRawBody(String rawBody, int bodyByteLength,
    {List<Map<String, dynamic>> customManifests = const []}) {
  // Item 39: bada body sirf upload actions ke liye allowed. Pehle cheap
  // string check (parse se pehle), phir parse ke baad pakka check.
  final mayBeUpload = rawBody.contains('"files.write"') || rawBody.contains('"data.upload"');
  final bodyLimit = mayBeUpload ? maxUploadRequestBodyBytes : maxRequestBodyBytes;
  if (bodyByteLength > bodyLimit) {
    return EnvelopeValidationResult.invalid(ValidationError(
        'Request body $bodyLimit bytes se zyada hai — reject',
        kind: 'PAYLOAD_TOO_LARGE'));
  }

  Map<String, dynamic> decoded;
  try {
    final parsed = jsonDecode(rawBody);
    if (parsed is! Map<String, dynamic>) {
      return const EnvelopeValidationResult.invalid(
          ValidationError('Command envelope ek JSON object hona chahiye'));
    }
    decoded = parsed;
  } on FormatException catch (e) {
    return EnvelopeValidationResult.invalid(
        ValidationError('Malformed JSON: ${e.message}'));
  }

  if (bodyByteLength > maxRequestBodyBytes && !_isUploadAction(decoded['action'])) {
    return EnvelopeValidationResult.invalid(ValidationError(
        'Request body $maxRequestBodyBytes bytes se zyada hai — reject',
        kind: 'PAYLOAD_TOO_LARGE'));
  }

  return validateEnvelopeShape(decoded, customManifests: customManifests);
}

/// Already-decoded envelope ka structural + schema validation. Yeh
/// function khud koi JSON parse nahi karta (caller ne already kar liya
/// hota hai), taaki dono entry points (`validateRawBody` aur koi bhi
/// jagah jahan envelope already Map ho) isi ek logic ko reuse kar sakein.
EnvelopeValidationResult validateEnvelopeShape(Map<String, dynamic> envelope,
    {List<Map<String, dynamic>> customManifests = const []}) {
  // ---- required top-level fields: presence + type -----------------------
  final requestId = envelope['request_id'];
  if (requestId is! String || requestId.isEmpty) {
    return const EnvelopeValidationResult.invalid(
        ValidationError('"request_id" required hai aur ek non-empty string honi chahiye'));
  }

  final apiKeyId = envelope['api_key_id'];
  if (apiKeyId is! String || apiKeyId.isEmpty) {
    return const EnvelopeValidationResult.invalid(
        ValidationError('"api_key_id" required hai aur ek non-empty string honi chahiye'));
  }

  final capability = envelope['capability'];
  if (capability is! String || capability.isEmpty) {
    return const EnvelopeValidationResult.invalid(
        ValidationError('"capability" required hai aur ek non-empty string honi chahiye'));
  }

  final action = envelope['action'];
  if (action is! String || action.isEmpty) {
    return const EnvelopeValidationResult.invalid(
        ValidationError('"action" required hai aur ek non-empty string honi chahiye'));
  }

  // ---- capability/action known hain? -------------------------------------
  final actionIndex = _buildActionIndex(customManifests);
  final entry = actionIndex[action];
  if (entry == null) {
    return EnvelopeValidationResult.invalid(
        ValidationError('Unknown action "$action" — koi registered capability is action ko support nahi karti'));
  }
  if (entry.capability != capability) {
    return EnvelopeValidationResult.invalid(ValidationError(
        'Action "$action" capability "${entry.capability}" ki hai, "$capability" ki nahi — '
        'envelope ka "capability" field mismatch hai'));
  }

  // ---- params: type + schema ----------------------------------------------
  final rawParams = envelope['params'];
  Map<String, dynamic> params;
  if (rawParams == null) {
    params = const {};
  } else if (rawParams is Map<String, dynamic>) {
    params = rawParams;
  } else {
    return const EnvelopeValidationResult.invalid(
        ValidationError('"params" present ho to ek JSON object hona chahiye'));
  }

  final paramsError = _validateParams(params, entry.schema, action);
  if (paramsError != null) {
    return EnvelopeValidationResult.invalid(paramsError);
  }

  // ---- payload: base64 string ya null -------------------------------------
  final payload = envelope['payload'];
  if (payload != null && payload is! String) {
    return const EnvelopeValidationResult.invalid(
        ValidationError('"payload" present ho to ek base64 string ya null hona chahiye'));
  }

  // ---- timeout_ms: bounds ---------------------------------------------------
  final timeoutMs = envelope['timeout_ms'];
  if (timeoutMs != null) {
    if (timeoutMs is! num || timeoutMs < minTimeoutMs || timeoutMs > maxTimeoutMs) {
      return EnvelopeValidationResult.invalid(ValidationError(
          '"timeout_ms" present ho to $minTimeoutMs se $maxTimeoutMs ke beech ek number hona chahiye'));
    }
  }

  return EnvelopeValidationResult.valid(envelope);
}

ValidationError? _validateParams(
    Map<String, dynamic> params, Map<String, dynamic> schema, String action) {
  if (schema.isEmpty) return null; // koi params zaroori nahi is action ke liye

  final required = (schema['required'] as List<dynamic>?)?.cast<String>() ?? const [];
  for (final field in required) {
    if (!params.containsKey(field) || params[field] == null) {
      return ValidationError('"$action" ke params mein "$field" required hai');
    }
  }

  final requiredOneOf =
      (schema['requiredOneOf'] as List<dynamic>?)?.cast<String>();
  if (requiredOneOf != null && requiredOneOf.isNotEmpty) {
    final hasOne = requiredOneOf.any((f) => params[f] != null);
    if (!hasOne) {
      return ValidationError(
          '"$action" ke params mein in mein se kam-se-kam ek chahiye: ${requiredOneOf.join(", ")}');
    }
  }

  final properties = schema['properties'] as Map<String, dynamic>? ?? const {};
  final allowAdditional = schema['additionalProperties'] == true;

  for (final entry in params.entries) {
    final fieldSchema = properties[entry.key] as Map<String, dynamic>?;
    if (fieldSchema == null) {
      if (!allowAdditional) {
        return ValidationError(
            '"$action" ke params mein "${entry.key}" ek unrecognized field hai');
      }
      continue; // allowAdditional == true, is field ka koi type-check nahi hai
    }
    final fieldError = _validateField(entry.key, entry.value, fieldSchema, action);
    if (fieldError != null) return fieldError;
  }

  return null;
}

ValidationError? _validateField(
    String name, dynamic value, Map<String, dynamic> fieldSchema, String action) {
  final type = fieldSchema['type'] as String?;
  switch (type) {
    case 'string':
      if (value is! String) {
        return ValidationError('"$action" params."$name" ek string honi chahiye');
      }
      final maxLength = fieldSchema['maxLength'] as int?;
      if (maxLength != null && value.length > maxLength) {
        return ValidationError(
            '"$action" params."$name" $maxLength characters se zyada lambi hai');
      }
      final enumValues = (fieldSchema['enum'] as List<dynamic>?)?.cast<String>();
      if (enumValues != null && !enumValues.contains(value)) {
        return ValidationError(
            '"$action" params."$name" in values mein se ek honi chahiye: ${enumValues.join(", ")}');
      }
      return null;

    case 'number':
      if (value is! num) {
        return ValidationError('"$action" params."$name" ek number honi chahiye');
      }
      final minimum = fieldSchema['minimum'] as num?;
      if (minimum != null && value < minimum) {
        return ValidationError('"$action" params."$name" kam-se-kam $minimum honi chahiye');
      }
      final maximum = fieldSchema['maximum'] as num?;
      if (maximum != null && value > maximum) {
        return ValidationError('"$action" params."$name" zyada-se-zyada $maximum honi chahiye');
      }
      return null;

    case 'boolean':
      if (value is! bool) {
        return ValidationError('"$action" params."$name" ek boolean honi chahiye');
      }
      return null;

    default:
      // Schema mein type specify nahi hui — koi type-check nahi (jaan-
      // bujh kar permissive, is se koi security guarantee nahi todti
      // kyunki unknown-field rejection upar already ho chuki hai).
      return null;
  }
}
