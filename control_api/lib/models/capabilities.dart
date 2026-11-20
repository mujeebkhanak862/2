/// `GET /capabilities` — sab 9 capabilities jo device-side already ban
/// chuki hain (shared_app native code), unke manifests. Format Dart
/// client ke `CapabilityManifest.fromJson` (Section 1.2) se match karta
/// hai.
///
/// **P0-04**: `params_schema` pehle har action ke liye khaali `{}` tha —
/// matlab discovery API (`GET /capabilities`) clients ko batati hi nahi
/// thi ke kis action ko kaunse params chahiye (ek chhoti si "fake
/// completeness" thi). Ab yeh field real, field names `shared_app/lib/
/// protocol/agent_connection.dart` ke actual dispatcher code se match
/// karte hain (guess nahi kiye gaye) — yehi schema `validation/
/// schema_validator.dart` bhi use karta hai request validate karne ke
/// liye, is liye discovery aur enforcement kabhi drift nahi karenge
/// (dono ek hi source of truth se aate hain).
library;

List<Map<String, dynamic>> builtInCapabilityManifests() => [
      _manifest('screen', requiredPermission: 'screen_view', actions: [
        _action('screen.capture', risk: 'medium'),
        _action('screen.watch_live', risk: 'medium', schema: {
          'required': ['session_id'],
          'properties': {
            'session_id': _stringField(),
            // Optional: smooth live view ke liye (battery/bandwidth badhta hai).
            'fps': _numberField(),
            'quality': _stringField(enumValues: ['low', 'medium', 'high', 'ultra']),
          },
        }),
        _action('screen.stop_live', risk: 'low', schema: {
          'required': ['session_id'],
          'properties': {'session_id': _stringField()},
        }),
      ]),
      // Stage 9.2: system-audio live stream — screen wali hi MediaProjection
      // consent se chalti hai, isliye `screen_view` permission reuse hoti hai
      // (`screenView` scope field — dekhein `models/api_key.dart`). Android
      // 10+ hi supported; doosre platforms par `CAPABILITY_UNAVAILABLE`.
      _manifest('audio', requiredPermission: 'screen_view', actions: [
        _action('audio.watch_live', risk: 'medium', schema: {
          'required': ['session_id'],
          'properties': {'session_id': _stringField()},
        }),
        _action('audio.stop_live', risk: 'low', schema: {
          'required': ['session_id'],
          'properties': {'session_id': _stringField()},
        }),
      ]),
      _manifest('input', requiredPermission: 'touch_input', actions: [
        _action('input.tap', risk: 'medium', schema: {
          'required': ['x', 'y'],
          'properties': {'x': _numberField(), 'y': _numberField()},
        }),
        _action('input.swipe', risk: 'medium', schema: {
          'required': ['x1', 'y1', 'x2', 'y2'],
          'properties': {
            'x1': _numberField(),
            'y1': _numberField(),
            'x2': _numberField(),
            'y2': _numberField(),
            'duration_ms': _numberField(minimum: 0, maximum: 60000),
          },
        }),
        // Android navigation (Back/Home/Recents/Notifications) — website ke
        // bina physical buttons ke phone chalane ke liye. Sirf Android.
        _action('input.key', risk: 'medium', schema: {
          'required': ['key'],
          'properties': {
            'key': _stringField(enumValues: ['back', 'home', 'recents', 'notifications']),
          },
        }),
        _action('input.type_text', risk: 'medium', schema: {
          'required': ['text'],
          // Item 66: `append: true` => focused field ke maujooda text ke
          // baad jodta hai (default: purana text replace).
          'properties': {
            'text': _stringField(maxLength: 10000),
            'append': {'type': 'boolean'},
          },
        }),
      ]),
      _manifest('files', requiredPermission: 'files', actions: [
        _action('files.list', risk: 'low', schema: {
          'required': ['path'],
          'properties': {'path': _stringField(maxLength: 4096)},
        }),
        _action('files.read', risk: 'medium', schema: {
          // Device code accepts `path` ya legacy `target_path` — dono
          // mein se kam-se-kam ek chahiye (`requiredOneOf`).
          'requiredOneOf': ['path', 'target_path'],
          'properties': {
            'path': _stringField(maxLength: 4096),
            'target_path': _stringField(maxLength: 4096),
          },
        }),
        _action('files.write', risk: 'high', schema: {
          'requiredOneOf': ['path', 'target_path'],
          'properties': {
            'path': _stringField(maxLength: 4096),
            'target_path': _stringField(maxLength: 4096),
          },
          // Actual file content `payload` (base64) mein jaata hai, params
          // mein nahi — payload ki size/MIME validation P1-08 ka scope
          // hai (Data Channel Hardening), yahan sirf path validate hota
          // hai.
        }),
        _action('files.delete', risk: 'high', schema: {
          'required': ['path'],
          'properties': {'path': _stringField(maxLength: 4096)},
        }),
      ]),
      _manifest('app_launcher', requiredPermission: 'apps', actions: [
        _action('app_launcher.launch', risk: 'medium', schema: {
          'required': ['identifier'],
          'properties': {'identifier': _stringField(maxLength: 512)},
        }),
        _action('app_launcher.list', risk: 'low'),
      ]),
      _manifest('browser', requiredPermission: 'browser', actions: [
        _action('browser.navigate', risk: 'medium', schema: {
          'required': ['url'],
          'properties': {'url': _stringField(maxLength: 8192)},
        }),
        _action('browser.click', risk: 'medium', schema: {
          // NOTE: device-side abhi is action ke liye visible text se
          // dhoondta hai (`findAndClick`), coordinate se nahi — is liye
          // param naam yahan `text` hai, `selector` nahi.
          'required': ['text'],
          'properties': {'text': _stringField(maxLength: 512)},
        }),
        _action('browser.type_text', risk: 'medium', schema: {
          'required': ['field_label', 'text'],
          'properties': {
            'field_label': _stringField(maxLength: 512),
            'text': _stringField(maxLength: 10000),
          },
        }),
        _action('browser.read', risk: 'low'),
      ]),
      _manifest('clipboard', requiredPermission: 'clipboard', actions: [
        _action('clipboard.read', risk: 'medium'),
        _action('clipboard.write', risk: 'low', schema: {
          'required': ['text'],
          'properties': {'text': _stringField(maxLength: 100000)},
        }),
      ]),
      _manifest('data', requiredPermission: 'data_transfer', actions: [
        _action('data.upload', risk: 'high', schema: {
          'requiredOneOf': ['path', 'target_path'],
          'properties': {
            'path': _stringField(maxLength: 4096),
            'target_path': _stringField(maxLength: 4096),
          },
        }),
        _action('data.download', risk: 'medium', schema: {
          'requiredOneOf': ['path', 'target_path'],
          'properties': {
            'path': _stringField(maxLength: 4096),
            'target_path': _stringField(maxLength: 4096),
          },
        }),
      ]),
      _manifest('contacts', requiredPermission: 'contacts', actions: [
        _action('contacts.list', risk: 'medium'),
      ], platformSupport: const ['android']), // Desktop OS mein unified contacts API nahi hota
      _manifest('control', requiredPermission: null, actions: [
        // control.switch ka asal delivery `/sessions/{id}/switch` (dedicated
        // REST route) se hoti hai, is generic `/commands` envelope se
        // nahi — schema yahan sirf discovery-completeness ke liye hai.
        _action('control.switch', risk: 'low', schema: {
          'required': ['switch_type', 'value'],
          'properties': {
            'switch_type': _stringField(
                enumValues: ['device', 'viewing_mode', 'api_key', 'capability_target']),
            'value': _stringField(maxLength: 256),
          },
        }),
        _action('control.pause', risk: 'low', schema: {
          'required': ['session_id'],
          'properties': {'session_id': _stringField()},
        }),
        _action('control.resume', risk: 'low', schema: {
          'required': ['session_id'],
          'properties': {'session_id': _stringField()},
        }),
        _action('control.stop', risk: 'low', schema: {
          'required': ['session_id'],
          'properties': {'session_id': _stringField()},
        }),
        // Audit fix (Section 8 / Section 13 #2) — explicit completion/
        // failure transitions (control_api/lib/routes/commands.dart's
        // `_serverOnlyControlActions` — device tak forward nahi hoti,
        // server-authoritative hai).
        _action('control.complete', risk: 'low', schema: {
          'required': ['session_id'],
          'properties': {'session_id': _stringField()},
        }),
        _action('control.fail', risk: 'low', schema: {
          'required': ['session_id'],
          'properties': {
            'session_id': _stringField(),
            'reason': _stringField(maxLength: 2000),
          },
        }),
      ]),
      _manifest('location', requiredPermission: null, actions: [
        _action('location.refresh', risk: 'medium'),
      ]),
      _manifest('background', requiredPermission: null, actions: [
        _action('background.keepalive', risk: 'low'),
        // `platform_support: ['android']` — audit's "Practical Reality"
        // table: notification listener aur messaging adapters filhaal
        // sirf Android permission/service paths ke liye scoped hain.
        // Item 84: Android NotificationListenerService se recent
        // notifications (memory-only ring buffer, max 100). `limit` 1-100
        // (default 20), `since_ms` = epoch ms ke baad ki.
        _action('notifications.read_event', risk: 'medium',
            schema: {
              'properties': {
                'limit': {'type': 'number'},
                'since_ms': {'type': 'number'},
              },
            },
            platformSupport: const ['android'],
            implemented: true),
        // P1-06: provider-specific messaging adapters (Android, supported
        // apps ki notification inline-reply). Reply do-step hai: pehle
        // prepare_reply (draft), phir send_reply(draft_id) — single-use.
        _action('messaging.get_event', risk: 'medium',
            schema: {
              'properties': {
                'limit': _numberField(minimum: 1, maximum: 50),
                'since_ms': {'type': 'number'},
                'package': _stringField(maxLength: 128),
              },
            },
            platformSupport: const ['android'],
            implemented: true),
        _action('messaging.prepare_reply', risk: 'medium',
            schema: {
              'required': ['event_id', 'text'],
              'properties': {
                'event_id': _stringField(maxLength: 128),
                'text': _stringField(maxLength: 1000),
              },
            },
            platformSupport: const ['android'],
            implemented: true),
        _action('messaging.send_reply', risk: 'high',
            schema: {
              'required': ['draft_id'],
              'properties': {'draft_id': _stringField(maxLength: 128)},
            },
            platformSupport: const ['android'],
            implemented: true),
      ]),
    ];

Map<String, dynamic> _stringField(
        {int? maxLength, List<String>? enumValues}) =>
    {
      'type': 'string',
      if (maxLength != null) 'maxLength': maxLength,
      if (enumValues != null) 'enum': enumValues,
    };

Map<String, dynamic> _numberField({num? minimum, num? maximum}) => {
      'type': 'number',
      if (minimum != null) 'minimum': minimum,
      if (maximum != null) 'maximum': maximum,
    };

Map<String, dynamic> _action(String name,
        {required String risk,
        Map<String, dynamic>? schema,
        List<String>? platformSupport,
        // P1-06 — false jab action ka manifest/schema declare ho chuka
        // hai lekin device-side dispatcher mein abhi genuinely koi kaam
        // karne wala code nahi hai (jaise messaging/notifications —
        // native OS integration chahiye). AI Tool Registry
        // (`ai_tools/ai_tool_registry.dart`) isko filter karta hai —
        // taaki AI ko kabhi ek aisa "tool" na dikhe jo hamesha fail
        // karega.
        bool implemented = true}) =>
    {
      'name': name,
      'params_schema': schema ?? <String, dynamic>{},
      'risk_level': risk,
      // P1-02 — is action ka apna platform override (agar manifest-level
      // se alag ho). null matlab "manifest ke `platform_support` se
      // inherit karo" (`ai_tools/ai_tool_registry.dart` isi convention
      // ko follow karta hai).
      if (platformSupport != null) 'platform_support': platformSupport,
      if (!implemented) 'implemented': false,
    };

Map<String, dynamic> _manifest(
  String capability, {
  required String? requiredPermission,
  required List<Map<String, dynamic>> actions,
  // P1-02 — is capability ka default platform support (per-action
  // override upar `_action()` se ho sakta hai). Audit ke Section 3
  // ("Practical Reality" table) se derive kiya gaya hai — koi guess
  // nahi, project ki apni documented reality use ki hai.
  List<String> platformSupport = const ['android', 'windows', 'linux'],
}) =>
    {
      'capability': capability,
      'version': '1.0.0',
      'actions': actions,
      'required_permission': requiredPermission ?? '',
      'default_policy': 'ask',
      'platform_support': platformSupport,
    };
