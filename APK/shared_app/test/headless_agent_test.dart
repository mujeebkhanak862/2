import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/config/credential_store.dart';
import 'package:shared_app/platform_channels/platform_channel_bridge.dart';
import 'package:shared_app/protocol/api_key.dart';
import 'package:shared_app/protocol/headless_agent.dart';

class _FakeStore implements CredentialStore {
  final StoredCredentials? creds;
  _FakeStore(this.creds);
  @override
  Future<StoredCredentials?> loadCredentials() async => creds;
  @override
  Future<void> saveCredentials(StoredCredentials c) async {}
  @override
  Future<ApiKeyScope?> loadPolicy() async => null;
  @override
  Future<void> savePolicy(ApiKeyScope scope) async {}
  @override
  Future<void> clear() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('headless channel name matches native ChannelNames.headless', () {
    expect(ChannelNames.headless, 'device_agent/headless');
  });

  test('agentMain tells native to stop itself when device is not paired', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('device_agent/headless'),
            (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('device_agent/headless'), null));

    await HeadlessAgentRunner(store: _FakeStore(null)).run();
    expect(calls, ['stopSelf']);
  });
}
