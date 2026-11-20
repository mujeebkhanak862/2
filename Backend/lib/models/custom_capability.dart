/// P1-01 — Persistent Capability Registry + Trust Validation.
///
/// Pehle `POST /capabilities/register` sirf `capability` aur `actions`
/// ki *presence* check karta tha — koi shape/type validation nahi thi,
/// koi persistence nahi thi (server restart par sab gayab), aur koi
/// authentication/trust check bhi nahi tha (koi bhi unauthenticated
/// request kuch bhi register kar sakti thi, including built-in
/// capability names ko "shadow"/override karna).
///
/// Yeh file sirf validation logic rakhti hai — route (`routes/
/// capabilities.dart`) trust check (auth) khud karta hai, yeh sirf
/// manifest ka *shape* validate karta hai.
library;

const _validRiskLevels = {'low', 'medium', 'high'};
const _validDefaultPolicies = {'ask', 'allow', 'deny'};

class ManifestValidationResult {
  final bool isValid;
  final String? error;
  const ManifestValidationResult._(this.isValid, this.error);
  factory ManifestValidationResult.valid() => const ManifestValidationResult._(true, null);
  factory ManifestValidationResult.invalid(String error) =>
      ManifestValidationResult._(false, error);
}

/// `builtInNames` — pehle se maujood (built-in + already-registered
/// custom) capability names, taaki koi naya registration inhe shadow/
/// overwrite na kar sake (audit: "privileged registration trust" — is
/// system mein "privileged namespace" hi built-in capability names
/// hain, koi bhi client unhe register/override nahi kar sakti).
ManifestValidationResult validateCustomManifest(
    Map<String, dynamic> manifest, Set<String> reservedNames) {
  final capability = manifest['capability'];
  if (capability is! String || capability.isEmpty) {
    return ManifestValidationResult.invalid(
        '"capability" required hai aur ek non-empty string honi chahiye');
  }
  if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(capability)) {
    return ManifestValidationResult.invalid(
        '"capability" sirf lowercase letters, digits, underscore honi chahiye '
        '(jaise "my_connector"), shuru ek letter se');
  }
  if (reservedNames.contains(capability)) {
    return ManifestValidationResult.invalid(
        'Capability name "$capability" already reserved hai (built-in ya '
        'pehle se registered) — koi bhi client isse shadow/override nahi kar sakti');
  }

  final version = manifest['version'];
  if (version is! String || version.isEmpty) {
    return ManifestValidationResult.invalid('"version" required hai (e.g. "1.0.0")');
  }

  final requiredPermission = manifest['required_permission'];
  if (requiredPermission != null && requiredPermission is! String) {
    return ManifestValidationResult.invalid('"required_permission" string honi chahiye');
  }

  final defaultPolicy = manifest['default_policy'] as String? ?? 'ask';
  if (!_validDefaultPolicies.contains(defaultPolicy)) {
    return ManifestValidationResult.invalid(
        '"default_policy" in mein se ek honi chahiye: ${_validDefaultPolicies.join(", ")}');
  }

  final actions = manifest['actions'];
  if (actions is! List || actions.isEmpty) {
    return ManifestValidationResult.invalid('"actions" ek non-empty list honi chahiye');
  }

  final seenActionNames = <String>{};
  for (final rawAction in actions) {
    if (rawAction is! Map) {
      return ManifestValidationResult.invalid('Har action ek JSON object hona chahiye');
    }
    final action = rawAction;
    final name = action['name'];
    if (name is! String || name.isEmpty) {
      return ManifestValidationResult.invalid(
          'Har action mein "name" required hai (non-empty string)');
    }
    if (!name.startsWith('$capability.')) {
      return ManifestValidationResult.invalid(
          'Action "$name" ka naam "$capability." se shuru hona chahiye (convention: '
          '"<capability>.<verb>")');
    }
    if (!seenActionNames.add(name)) {
      return ManifestValidationResult.invalid('Action "$name" is manifest mein duplicate hai');
    }

    final riskLevel = action['risk_level'];
    if (riskLevel is! String || !_validRiskLevels.contains(riskLevel)) {
      return ManifestValidationResult.invalid(
          'Action "$name" ka "risk_level" in mein se ek honi chahiye: '
          '${_validRiskLevels.join(", ")}');
    }

    final paramsSchema = action['params_schema'];
    if (paramsSchema != null && paramsSchema is! Map) {
      return ManifestValidationResult.invalid('Action "$name" ka "params_schema" ek object honi chahiye');
    }

    // P1-02 — per-action platform override (optional; na diya jaaye to
    // manifest-level `platform_support` se inherit hota hai).
    final actionPlatformSupport = action['platform_support'];
    if (actionPlatformSupport != null) {
      final err = _validatePlatformList(actionPlatformSupport, 'Action "$name"');
      if (err != null) return err;
    }
  }

  final platformSupport = manifest['platform_support'];
  if (platformSupport != null) {
    final err = _validatePlatformList(platformSupport, '"platform_support"');
    if (err != null) return err;
  }

  return ManifestValidationResult.valid();
}

const _validPlatforms = {'android', 'windows', 'linux'};

ManifestValidationResult? _validatePlatformList(dynamic value, String label) {
  if (value is! List) {
    return ManifestValidationResult.invalid('$label (agar diya jaaye) ek list honi chahiye');
  }
  for (final p in value) {
    if (p is! String || !_validPlatforms.contains(p)) {
      return ManifestValidationResult.invalid(
          '$label mein sirf yeh values allowed hain: ${_validPlatforms.join(", ")}');
    }
  }
  return null;
}

/// **Trust check** (audit: "Untrusted client ko privileged capability
/// register na karne dein"). Kisi bhi action ka `risk_level == 'high'`
/// hona manifest ko "privileged" banata hai. Registration route
/// (`routes/capabilities.dart`) is check ko device-authentication ke
/// saath combine karta hai: device-authenticated client bhi high-risk
/// capability register nahi kar sakta — is system mein filhaal koi
/// "admin"-level trust tier nahi hai, is liye conservative default yeh
/// hai ke high-risk custom capabilities bilkul register hi na hon
/// (agar future mein koi trusted-operator tier add ho, tabhi relax
/// karna).
bool manifestIsPrivileged(Map<String, dynamic> manifest) {
  final actions = manifest['actions'] as List? ?? const [];
  for (final rawAction in actions) {
    if (rawAction is Map && rawAction['risk_level'] == 'high') return true;
  }
  return false;
}
