/// P1-02 — AI Tool Registry — Device-Aware + Policy-Aware.
///
/// Yeh "AI integration boundary" hai — audit ne explicitly kaha "AI
/// engine khud invent mat karo": yeh file koi AI model, koi orchestration
/// loop, koi tool-calling runtime nahi hai. Yeh sirf ek pure function
/// hai — validated capability manifests (built-in + P1-01 ke persistent
/// custom registrations) se, ek selected device aur active API key ke
/// context mein, **konse tools abhi call-able hain** yeh nikalta hai.
/// Jo bhi AI engine iske upar banaya jaaye (Claude, GPT, koi bhi), woh
/// is list ko apne tool-definitions format mein map kar sakta hai.
///
/// Do independent filters (audit: "sirf selected device ki supported
/// capabilities aur active API-key/policy allowed actions"):
///   1. **Device-aware**: agar action/manifest ka `platform_support`
///      diya gaya hai aur device ka platform maloom hai, to us platform
///      ke liye unsupported actions list mein nahi aatin (jaise
///      `contacts.list` Windows device ke liye kabhi nahi aayega).
///   2. **Policy-aware**: built-in actions ke liye `ApiKeyScope.
///      allowsAction()` se gate hota hai — jo action us key ke scope
///      mein allowed nahi, woh list mein nahi aata.
///
/// **Audit fix applied** (P1-02, pehle "Known boundary" yahan documented
/// thi): custom (P1-01 se registered) capabilities ab bhi policy-gated
/// hain — `ApiKeyScope.customCapabilities` (naya field, `models/
/// api_key.dart`) se, capability-name granularity par. Registration ke
/// waqt hi kisi API key ko koi custom capability access nahi milta —
/// registration sirf capability ko *system mein* register karta hai;
/// use karne ke liye har key ko explicitly `custom_capabilities` list
/// mein us capability ka naam dena hota hai.
library;

import '../models/api_key.dart';
import '../models/capabilities.dart';
import '../models/device.dart';

/// Ek AI tool definition — provider-agnostic shape (Anthropic/OpenAI
/// jaise tool-calling formats se easily map ho jaata hai: `name`,
/// `description`, `input_schema`).
class AiToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final String riskLevel;
  final String capability;

  AiToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.riskLevel,
    required this.capability,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'input_schema': inputSchema,
        'risk_level': riskLevel,
        'capability': capability,
      };
}

/// **Core entry point.** `device` — jis device ke liye tools chahiye
/// (uska `platform` filter #1 ke liye use hota hai). `scope` — caller
/// ki API key ka scope (filter #2 ke liye, built-in actions par).
/// `customManifests` — P1-01 registry se (`AppState.
/// customCapabilityManifests`).
List<AiToolDefinition> buildAiTools({
  required Device device,
  required ApiKeyScope scope,
  required List<Map<String, dynamic>> customManifests,
}) {
  final tools = <AiToolDefinition>[];

  for (final manifest in builtInCapabilityManifests()) {
    _collectToolsFrom(manifest, device, scope, isCustom: false, out: tools);
  }
  for (final manifest in customManifests) {
    // Audit fix (P1-02): pehle yahan `scope: null` pass hota tha, jo
    // filter #2 (policy-aware) ko poori tarah skip kar deta — matlab
    // koi bhi API key, chahe uske paas is custom capability ki koi
    // permission na di gayi ho, use AI tool ke tor par dekh/call kar
    // sakti thi. Ab scope hamesha pass hota hai; andar `isCustom: true`
    // ke through pata chalta hai ke `allowsCustomCapability()` se check
    // karna hai, `allowsAction()` se nahi (jo custom ke liye kabhi kaam
    // nahi karta — dekhein `models/api_key.dart`).
    _collectToolsFrom(manifest, device, scope, isCustom: true, out: tools);
  }

  return tools;
}

void _collectToolsFrom(Map<String, dynamic> manifest, Device device, ApiKeyScope scope,
    {required bool isCustom, required List<AiToolDefinition> out}) {
  final capability = manifest['capability'] as String;
  final manifestPlatforms = (manifest['platform_support'] as List<dynamic>?)?.cast<String>();
  final actions = manifest['actions'] as List<dynamic>? ?? const [];

  for (final rawAction in actions) {
    final action = rawAction as Map<String, dynamic>;
    final name = action['name'] as String;

    // ---- Filter #0: implemented? (P1-06) --------------------------------
    // Kuch actions ka manifest/schema declare ho chuka hai lekin device-
    // side genuinely koi kaam karne wala code nahi hai abhi (jaise
    // messaging/notifications — native OS integration chahiye). Aisi
    // actions AI ko tool ke tor par kabhi nahi dikhni chahiyein — warna
    // AI ek aisa tool try karega jo hamesha CAPABILITY_UNAVAILABLE
    // fail karega.
    if (action['implemented'] == false) continue;

    // ---- Filter #1: device-aware (platform) ----------------------------
    // Action-level override manifest-level se priority leta hai. Device
    // ka platform 'unknown' ho (purana paired device, P1-02 se pehle ka)
    // to filter skip — permissive fallback, tools chhupte nahi.
    final effectivePlatforms =
        (action['platform_support'] as List<dynamic>?)?.cast<String>() ?? manifestPlatforms;
    if (device.platform != 'unknown' &&
        effectivePlatforms != null &&
        !effectivePlatforms.contains(device.platform)) {
      continue; // is device ke platform par yeh action support hi nahi
    }

    // ---- Filter #2: policy-aware (API key scope) ------------------------
    // Custom capabilities ke liye `allowsAction()` kaam nahi karta (woh
    // sirf built-in fixed action set jaanta hai, fail-closed) — is liye
    // capability-name-level check (`allowsCustomCapability`) use karte
    // hain (P1-02 audit fix).
    // Item 46: `control.*` ke liye `allowsAction` hamesha false hai (unka
    // asli authorization per-task hota hai: task ki originating capability
    // ka scope — `routes/commands.dart`). Isliye pehle AI ko
    // `control.complete`/`control.fail` (jo AI orchestrator ke liye hi bane
    // hain) kabhi dikhte hi nahi the. Ab: agar key ke paas koi bhi
    // task-creating capability hai to control tools dikhte hain
    // (call-time par phir bhi per-task check lagta hai). `control.switch`
    // `/commands` se callable nahi hai (dedicated REST route), isliye
    // tool ke tor par expose nahi hota.
    final bool actionAllowed;
    if (capability == 'control' && !isCustom) {
      actionAllowed = name != 'control.switch' && _hasAnyTaskCapability(scope);
    } else {
      actionAllowed =
          isCustom ? scope.allowsCustomCapability(capability) : scope.allowsAction(name);
    }
    if (!actionAllowed) {
      continue; // is API key ke paas is action/capability ka scope nahi hai
    }

    final paramsSchema = action['params_schema'] as Map<String, dynamic>? ?? const {};
    out.add(AiToolDefinition(
      name: name,
      description: _descriptionFor(name) ?? 'No description available for "$name".',
      inputSchema: _toInputSchema(paramsSchema),
      riskLevel: action['risk_level'] as String? ?? 'medium',
      capability: capability,
    ));
  }
}

/// Internal `params_schema` shape (`required`/`properties`/
/// `requiredOneOf`/`additionalProperties`) ko ek standard JSON-Schema-
/// jaisi `input_schema` mein badalta hai (jo zyada-tar tool-calling
/// APIs expect karte hain).
bool _hasAnyTaskCapability(ApiKeyScope scope) =>
    scope.screenView ||
    scope.touchInput ||
    scope.keyboardText ||
    scope.files ||
    scope.apps ||
    scope.browser ||
    scope.clipboard ||
    scope.dataTransfer ||
    scope.contacts ||
    scope.location ||
    scope.background ||
    scope.messagingReply ||
    scope.customCapabilities.isNotEmpty;

Map<String, dynamic> _toInputSchema(Map<String, dynamic> paramsSchema) {
  final properties = paramsSchema['properties'] as Map<String, dynamic>? ?? const {};
  final required = (paramsSchema['required'] as List<dynamic>?)?.cast<String>();
  final requiredOneOf = (paramsSchema['requiredOneOf'] as List<dynamic>?)?.cast<String>();

  final schema = <String, dynamic>{
    'type': 'object',
    'properties': properties,
  };
  if (required != null && required.isNotEmpty) {
    schema['required'] = required;
  }
  if (requiredOneOf != null && requiredOneOf.isNotEmpty) {
    // Standard JSON Schema mein "in se koi ek required" ke liye `oneOf`
    // composition chahiye hoti — poori JSON-Schema oneOf-over-required
    // machinery yahan implement karna is scope se bahar hai, is liye
    // ek seedha, LLM-readable hint field use karte hain.
    schema['required_one_of'] = requiredOneOf;
  }
  return schema;
}

/// Har built-in action ka human-readable description — AI tool-calling
/// ke liye zaroori hai (bina description, LLM ko pata hi nahi chalega
/// tool kab use karna hai). Custom capabilities ke liye description
/// registration ke waqt khud manifest mein aa sakti hai (future
/// extension — abhi tak koi built-in description-field convention
/// custom manifests ke liye nahi hai, is liye unke liye generic fallback
/// text use hota hai).
String? _descriptionFor(String actionName) => _actionDescriptions[actionName];

const _actionDescriptions = {
  'screen.capture': 'Device ki screen ka ek single screenshot leta hai.',
  'screen.watch_live': 'Diye gaye session ke liye live screen streaming shuru karta hai.',
  'screen.stop_live': 'Chal rahi live screen stream ko band karta hai.',
  'audio.watch_live': 'Device ki system audio (PCM16, 16kHz, mono) ka live stream shuru karta hai (sirf Android 10+).',
  'audio.stop_live': 'Chal rahi live audio stream ko band karta hai.',
  'input.tap': 'Screen par diye gaye x,y coordinates par ek tap simulate karta hai. '
      'IMPORTANT: x,y **absolute pixel coordinates** hain (0,0 = top-left), '
      'us device ke real screen resolution ke against — bilkul wahi resolution '
      'jo sabse recent "screen.capture"/"screen.watch_live" frame ki image '
      'dimensions mein dikhta hai. Normalized (0.0–1.0) fractions NAHI hain — '
      'agar aisi coordinates bheji gayin, tap galat jagah lagega.',
  'input.swipe': 'Ek point se doosre point tak swipe gesture simulate karta hai. '
      'x1,y1,x2,y2 sab **absolute pixel coordinates** hain (0,0 = top-left) — '
      'dekhein "input.tap" ka coordinate contract, yahan bhi wahi lagu hota hai.',
  'input.key': 'Android navigation key dabata hai: back, home, recents ya notifications (sirf Android).',
  'input.type_text': 'Currently focused input field mein text type karta hai.',
  'files.list': 'Diye gaye path par files/folders ki list deta hai.',
  'files.read': 'Diye gaye path se file ka content padhta hai.',
  'files.write': 'Diye gaye path par file likhta hai (content base64 payload mein hota hai).',
  'files.delete': 'Diye gaye path par file delete karta hai.',
  'app_launcher.launch': 'Diye gaye identifier wali app open karta hai.',
  'app_launcher.list': 'Device par installed apps ki list deta hai.',
  'browser.navigate': 'Browser mein diye gaye URL par navigate karta hai.',
  'browser.click': 'Browser mein diye gaye visible text wale element par click karta hai.',
  'browser.type_text': 'Browser ke diye gaye labeled field mein text type karta hai.',
  'browser.read': 'Current browser page ka content padhta hai.',
  'clipboard.read': 'Device ke clipboard ka current content padhta hai.',
  'clipboard.write': 'Device ke clipboard mein text likhta hai.',
  'data.upload': 'Diya gaya file content device par diye gaye path par upload karta hai.',
  'data.download': 'Device se diye gaye path ki file download karta hai.',
  'contacts.list': "Device ki contact list padhta hai.",
  'control.switch': 'Session ka viewing mode ya target (device/API-key) switch karta hai.',
  'control.pause': 'Chal rahi task ko pause karta hai — koi nayi action tab tak dispatch nahi hoti.',
  'control.resume': 'Paused task ko wapas resume karta hai, last checkpoint se continue karke.',
  'control.stop': 'Task ko permanently stop karta hai.',
  'control.complete': 'Task ko explicitly COMPLETED mark karta hai (kaam safaltapoorvak khatam ho gaya).',
  'control.fail': 'Task ko explicitly FAILED mark karta hai (optional params.reason ke saath).',
  'location.refresh': 'Device ki current location fetch karta hai.',
  'background.keepalive': 'Background agent ko active/zinda rakhta hai.',
  'notifications.read_event':
      'Recent notifications padhta hai (Android, Notification access chahiye).',
  'messaging.get_event':
      'Supported messaging apps (WhatsApp, Telegram, Signal, Messenger, SMS apps) ke recent messages padhta hai — notification se, can_reply flag ke saath.',
  'messaging.prepare_reply':
      'Kisi message event ka reply draft banata hai (bhejta nahi). 5 minute valid draft_id deta hai.',
  'messaging.send_reply':
      'Taiyar draft_id ko app ki notification inline-reply se bhejta hai (single-use; delivery confirm nahi hoti).',
};
