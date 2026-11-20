// Stage 5 (Dart side): InputBridge ab native `false` ko error banata hai (item 65)
// aur typeText `append` bhejta hai (item 66).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/platform_channels/platform_channel_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(ChannelNames.input);
  final calls = <MethodCall>[];

  void mock(Object? Function(MethodCall) handler) {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('tap/swipe succeed on true or null', () async {
    mock((_) => true);
    await InputBridge().tap(1, 2);
    mock((_) => null);
    await InputBridge().swipe(1, 2, 3, 4);
  });

  test('tap/swipe throw GESTURE_FAILED when native returns false', () async {
    mock((_) => false);
    await expectLater(InputBridge().tap(1, 2),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'GESTURE_FAILED')));
    await expectLater(InputBridge().swipe(1, 2, 3, 4),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'GESTURE_FAILED')));
  });

  test('typeText throws NO_FOCUSED_FIELD on false and forwards append', () async {
    mock((_) => false);
    await expectLater(InputBridge().typeText('hi', append: true),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'NO_FOCUSED_FIELD')));
    expect(calls.single.arguments, {'text': 'hi', 'append': true});

    mock((_) => true);
    await InputBridge().typeText('x');
    expect(calls.single.arguments, {'text': 'x', 'append': false});
  });
}
