import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'dart:convert';
import '../protocol/api_client.dart';
import '../protocol/api_key.dart';
import '../protocol/capability_manifest.dart' hide RiskLevel;
import '../theme/app_theme.dart';
import 'permission_wizard.dart';

class KeyManagerScreen extends StatefulWidget {
  final DeviceAgentApiClient api;
  const KeyManagerScreen({super.key, required this.api});

  @override
  State<KeyManagerScreen> createState() => _KeyManagerScreenState();
}

class _KeyManagerScreenState extends State<KeyManagerScreen> {
  List<ApiKey> _keys = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final keys = await widget.api.listApiKeys();
      setState(() {
        _keys = keys;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Keys load nahi ho saki: $e';
        _loading = false;
      });
    }
  }

  Future<void> _createKey() async {
    final labelController = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Key Label'),
        content: TextField(
          controller: labelController,
          decoration: const InputDecoration(hintText: 'e.g. Backup Uploader'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, labelController.text.trim()),
              child: const Text('Next')),
        ],
      ),
    );
    if (label == null || label.isEmpty || !mounted) return;

    // Follow-up fix (P1-02) — registered custom capabilities fetch karte
    // hain taaki wizard unhe "Custom Capabilities" section mein dikha
    // sake. Fetch fail ho jaaye (network issue, waghera) to bhi wizard
    // khulti hai — sirf woh section khaali rahega, poora flow block nahi
    // hota is ek optional cheez ki wajah se.
    List<CapabilityManifest> customCapabilities = const [];
    try {
      final all = await widget.api.getCapabilities();
      customCapabilities = all.where((c) => c.isCustom).toList();
    } catch (_) {
      // Silently ignore — dekhein upar wala comment.
    }

    // Section 3.2 — same wizard as first-time setup.
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PermissionWizard(
          title: 'Scope for "$label"',
          availableCustomCapabilities: customCapabilities,
          onConfirm: (scope) async {
            Navigator.pop(context); // close wizard
            try {
              final newKey =
                  await widget.api.createApiKey(label: label, scope: scope);
              if (!mounted) return;
              await showDialog(
                context: context,
                builder: (ctx) => _KeyCreatedDialog(
                  keyId: newKey.keyId,
                  secret: newKey.secret ?? '',
                  controlApiUrl: widget.api.baseUrl.toString(),
                ),
              );
              _refresh();
            } catch (e) {
              if (!mounted) return;
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('Failed: $e')));
            }
          },
        ),
      ),
    );
  }

  Future<void> _setEnabled(ApiKey key, bool enabled) async {
    try {
      await widget.api.setApiKeyEnabled(key.keyId, enabled);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _revoke(ApiKey key) async {
    final scopes = key.scope.enabledScopes;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke Key?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('"${key.label}" turant band ho jayegi — ise use karne wala '
                  'har client agle request par reject hoga. Yeh wapas nahi ho sakta.'),
              const SizedBox(height: Spacing.md),
              Text('Risk: ${key.scope.riskLevel.label}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: Spacing.xs),
              Text('Last used: ${_lastUsedText(key)}'),
              const SizedBox(height: Spacing.sm),
              Text(scopes.isEmpty
                  ? 'Koi permission granted nahi thi.'
                  : 'Jo access hatega: ${scopes.map((e) => e.name).join(', ')}'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Revoke')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await widget.api.revokeApiKey(key.keyId);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Revoke failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('API Keys')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createKey,
        icon: const Icon(Icons.add),
        label: const Text('Create New API Key'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: _keys.isEmpty
                      ? ListView(children: const [
                          Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(
                                child: Text('Abhi koi API key nahi. '
                                    '"Create New API Key" se banayein.')),
                          )
                        ])
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(
                              Spacing.lg, Spacing.sm, Spacing.lg, 96),
                          itemCount: _keys.length,
                          itemBuilder: (ctx, i) => _keyCard(ctx, _keys[i]),
                        ),
                ),
    );
  }

  StatusTone _toneForRisk(RiskLevel r) => switch (r) {
        RiskLevel.high => StatusTone.danger,
        RiskLevel.medium => StatusTone.warning,
        RiskLevel.low => StatusTone.success,
        RiskLevel.none => StatusTone.neutral,
      };

  String _lastUsedText(ApiKey k) {
    final t = k.lastUsedAt;
    if (t == null) return 'kabhi use nahi hui';
    final d = DateTime.now().toUtc().difference(t.toUtc());
    if (d.inMinutes < 1) return 'abhi abhi';
    if (d.inHours < 1) return '${d.inMinutes} min pehle';
    if (d.inDays < 1) return '${d.inHours} ghante pehle';
    return '${d.inDays} din pehle';
  }

  Widget _keyCard(BuildContext context, ApiKey k) {
    final risk = k.scope.riskLevel;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.card),
        onTap: () => _showDetails(k),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(k.enabled ? Icons.vpn_key : Icons.vpn_key_off_outlined),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Text(k.label,
                        style: Theme.of(context).textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis),
                  ),
                  Switch(
                    value: k.enabled,
                    onChanged: k.isExpired ? null : (v) => _setEnabled(k, v),
                  ),
                  IconButton(
                    tooltip: 'Revoke',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _revoke(k),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [
                  StatusChip(
                    label: risk.label,
                    tone: _toneForRisk(risk),
                    icon: risk == RiskLevel.high
                        ? Icons.warning_amber_rounded
                        : Icons.shield_outlined,
                  ),
                  if (k.isExpired)
                    const StatusChip(
                        label: 'Expired', tone: StatusTone.danger, icon: Icons.timer_off_outlined)
                  else if (!k.enabled)
                    const StatusChip(
                        label: 'Disabled', tone: StatusTone.neutral, icon: Icons.pause_circle_outline),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Text(_scopeSummary(k.scope),
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: Spacing.xs),
              Text('Last used: ${_lastUsedText(k)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetails(ApiKey k) {
    final scopes = k.scope.enabledScopes;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
              Spacing.xl, 0, Spacing.xl, Spacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(k.label, style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Spacing.sm),
              StatusChip(
                  label: k.scope.riskLevel.label,
                  tone: _toneForRisk(k.scope.riskLevel)),
              const SizedBox(height: Spacing.lg),
              Text('Created: ${k.createdAt.toLocal()}'),
              Text('Last used: ${_lastUsedText(k)}'),
              if (k.expiresAt != null) Text('Expires: ${k.expiresAt!.toLocal()}'),
              const SectionHeader('Is key ke paas kya access hai'),
              if (scopes.isEmpty)
                const Text('Koi permission granted nahi.')
              else
                for (final sc in scopes)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(
                        sc.weight >= 3
                            ? Icons.warning_amber_rounded
                            : Icons.check_circle_outline,
                        color: sc.weight >= 3
                            ? Theme.of(ctx).colorScheme.error
                            : Theme.of(ctx).colorScheme.primary),
                    title: Text(sc.name),
                    subtitle: Text(sc.description),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  String _scopeSummary(ApiKeyScope s) {
    final on = <String>[
      if (s.screenView) 'Screen',
      if (s.touchInput) 'Input',
      if (s.keyboardText) 'Keyboard',
      if (s.files) 'Files',
      if (s.apps) 'Apps',
      if (s.browser) 'Browser',
      if (s.clipboard) 'Clipboard',
      if (s.dataTransfer) 'Data',
      if (s.contacts) 'Contacts',
      if (s.location) 'Location',
      if (s.background) 'Background',
      if (s.messagingReply) 'Messaging Reply',
    ];
    return on.isEmpty ? 'No permissions granted' : on.join(' · ');
  }
}

/// Naya key create hone ke turant baad dikhta hai — secret sirf **ek hi
/// baar** yahan visible hota hai (server dobara kabhi return nahi karta).
///
/// QR code isi secret ko ek compact JSON mein encode karta hai
/// (`{api_url, key_id, secret}`) — taaki koi doosra tool/device (jaise
/// ek AI agent setup screen) is key ko **scan karke** seedha le sake,
/// lambi secret string haath se type na karni pade. Yeh QR sirf isi
/// dialog mein dikhta hai, kahin save/log nahi hota.
class _KeyCreatedDialog extends StatelessWidget {
  final String keyId;
  final String secret;
  final String controlApiUrl;

  const _KeyCreatedDialog({
    required this.keyId,
    required this.secret,
    required this.controlApiUrl,
  });

  @override
  Widget build(BuildContext context) {
    final qrData = jsonEncode({
      'api_url': controlApiUrl,
      'key_id': keyId,
      'secret': secret,
    });

    return AlertDialog(
      title: const Text('Key Created'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: semanticOf(context).warning,
              borderRadius: BorderRadius.circular(Radii.chip),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    color: semanticOf(context).onWarning),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    'Yeh secret sirf ABHI, ek hi baar dikhega — dobara kabhi '
                    'nahi milega. Ise kisi ke saath share na karein, chat/'
                    'screenshot mein na daalein; kisi ko mil jaye to turant '
                    'revoke karein.',
                    style: TextStyle(color: semanticOf(context).onWarning),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // QR code — koi doosra device/tool isko scan karke seedha yeh
          // key use karna shuru kar sakta hai, type kiye bina.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: QrImageView(
              data: qrData,
              version: QrVersions.auto,
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Ya secret text copy karein:',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 4),
          SelectableText(secret, style: const TextStyle(fontFamily: 'monospace')),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
