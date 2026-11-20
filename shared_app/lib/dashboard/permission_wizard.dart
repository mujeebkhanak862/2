import 'package:flutter/material.dart';
import '../protocol/api_key.dart';
import '../protocol/capability_manifest.dart';

/// Section 3.2 — "Har Nayi Key Banate Waqt, Wahi Wizard Dobara". Isi wajah
/// se yeh ek standalone reusable widget hai: first-time app setup aur
/// "Create New API Key" dono isi ko call karte hain, taaki behavior kabhi
/// mismatch na ho.
class PermissionWizard extends StatefulWidget {
  final String title;
  final ApiKeyScope initialScope;
  final void Function(ApiKeyScope scope) onConfirm;

  /// Follow-up fix (P1-02) — registered custom (P1-01) capabilities,
  /// jinhe yeh wizard ab explicitly grant/revoke karne deta hai (per-key
  /// `ApiKeyScope.customCapabilities`). Caller isse `GET /capabilities`
  /// se fetch karke pass karta hai (dekhein `key_manager_screen.dart`).
  /// Empty list default hai — first-time device setup (`main.dart`) mein
  /// abhi koi API client hi available nahi hota is call ke waqt, is liye
  /// woh caller ise simply omit kar deta hai (koi custom capability
  /// section nahi dikhta, jo sahi hai — is stage par koi bhi custom
  /// capability kabhi register nahi hui hoti).
  final List<CapabilityManifest> availableCustomCapabilities;

  const PermissionWizard({
    super.key,
    this.title = 'Permissions',
    this.initialScope = const ApiKeyScope(),
    required this.onConfirm,
    this.availableCustomCapabilities = const [],
  });

  @override
  State<PermissionWizard> createState() => _PermissionWizardState();
}

class _PermissionWizardState extends State<PermissionWizard> {
  late bool screenView = widget.initialScope.screenView;
  late bool touchInput = widget.initialScope.touchInput;
  late bool keyboardText = widget.initialScope.keyboardText;
  late bool files = widget.initialScope.files;
  late bool apps = widget.initialScope.apps;
  late bool browser = widget.initialScope.browser;
  late bool clipboard = widget.initialScope.clipboard;
  late bool dataTransfer = widget.initialScope.dataTransfer;
  late bool contacts = widget.initialScope.contacts;
  late bool location = widget.initialScope.location;
  late bool background = widget.initialScope.background;
  late bool messagingReply = widget.initialScope.messagingReply;

  /// Follow-up fix (P1-02) — ab poora UI toggle hai, sirf data-loss-safe
  /// pass-through nahi. `Set.from(...)` se initialize karte hain taaki
  /// existing grants (edit-mode mein) checked dikhein.
  late Set<String> selectedCustomCapabilities =
      Set.from(widget.initialScope.customCapabilities);

  ApiKeyScope get _currentScope => ApiKeyScope(
        screenView: screenView,
        touchInput: touchInput,
        keyboardText: keyboardText,
        files: files,
        apps: apps,
        browser: browser,
        clipboard: clipboard,
        dataTransfer: dataTransfer,
        contacts: contacts,
        location: location,
        background: background,
        messagingReply: messagingReply,
        customCapabilities: selectedCustomCapabilities,
      );

  Future<void> _confirm() async {
    // Section 3.5 — high-risk combination ke liye extra confirmation.
    if (_currentScope.isHighRisk) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Are you sure?'),
          content: const Text(
              'Yeh key ek saath Touch/Input + Files + Data Transfer '
              'permission le rahi hai — high-risk combination hai.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Continue')),
          ],
        ),
      );
      if (sure != true) return;
    }
    widget.onConfirm(_currentScope);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        children: [
          _toggle('Screen View', 'Is key ko screen dekhne ki ijazat do?',
              screenView, (v) => setState(() => screenView = v)),
          _toggle('Touch/Input', 'Mouse/click/tap control do?', touchInput,
              (v) => setState(() => touchInput = v)),
          _toggle('Keyboard/Text', 'Typing/key input do?', keyboardText,
              (v) => setState(() => keyboardText = v)),
          _toggle('Files', 'File read/write access do?', files,
              (v) => setState(() => files = v)),
          _toggle('Apps', 'App open/launch karne do?', apps,
              (v) => setState(() => apps = v)),
          _toggle('Browser', 'Browser automation do?', browser,
              (v) => setState(() => browser = v)),
          _toggle('Clipboard', 'Clipboard access do?', clipboard,
              (v) => setState(() => clipboard = v)),
          _toggle(
              'Data Transfer',
              'Images/files bhejne-lene ki ijazat do?',
              dataTransfer,
              (v) => setState(() => dataTransfer = v)),
          _toggle('Contacts', 'Naam/number list padhne ki ijazat do?',
              contacts, (v) => setState(() => contacts = v)),
          _toggle('Location', 'Device ki location padhne ki ijazat do?',
              location, (v) => setState(() => location = v)),
          _toggle(
              'Background',
              'Locked/background state mein notifications padhne aur '
              'keepalive ki ijazat do?',
              background, (v) => setState(() => background = v)),
          _toggle(
              'Messaging Reply',
              'Background mein aa rahe messages ka reply bhejne ki '
              'ijazat do (alag se, kyunki yeh "Background" se zyada '
              'high-risk hai)?',
              messagingReply, (v) => setState(() => messagingReply = v)),
          if (widget.availableCustomCapabilities.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 24, 16, 4),
              child: Text('Custom Capabilities',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Yeh registered custom capabilities hain (P1-01) — built-in '
                'nahi. Har ek ko is key ke liye alag se grant karna padta '
                'hai, warna is key se koi custom action call nahi ho sakti.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            for (final manifest in widget.availableCustomCapabilities)
              CheckboxListTile(
                title: Text(manifest.capability),
                subtitle: Text(
                    '${manifest.actions.length} action(s) — ${manifest.actions.map((a) => a.name).join(", ")}'),
                value: selectedCustomCapabilities.contains(manifest.capability),
                onChanged: (checked) => setState(() {
                  if (checked ?? false) {
                    selectedCustomCapabilities.add(manifest.capability);
                  } else {
                    selectedCustomCapabilities.remove(manifest.capability);
                  }
                }),
              ),
          ],
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton(
              onPressed: _confirm,
              child: const Text('Confirm Permissions'),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _toggle(
      String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}
