import 'package:control_api/middleware/rate_limiter.dart';
import 'package:test/test.dart';

void main() {
  group('SlidingWindowLimiter (P0-05)', () {
    test('allows requests under the limit', () {
      final limiter =
          SlidingWindowLimiter(maxRequests: 3, window: const Duration(minutes: 1));
      expect(limiter.checkAndIncrement('id1'), isNull);
      expect(limiter.checkAndIncrement('id1'), isNull);
      expect(limiter.checkAndIncrement('id1'), isNull);
    });

    test('blocks the request that exceeds the limit, with a retry-after', () {
      final limiter =
          SlidingWindowLimiter(maxRequests: 2, window: const Duration(minutes: 1));
      expect(limiter.checkAndIncrement('id1'), isNull);
      expect(limiter.checkAndIncrement('id1'), isNull);
      final retry = limiter.checkAndIncrement('id1');
      expect(retry, isNotNull);
      expect(retry!, greaterThan(0));
      expect(retry, lessThanOrEqualTo(60));
    });

    test('different identities have independent buckets', () {
      final limiter =
          SlidingWindowLimiter(maxRequests: 1, window: const Duration(minutes: 1));
      expect(limiter.checkAndIncrement('id1'), isNull);
      expect(limiter.checkAndIncrement('id1'), isNotNull); // id1 exhausted
      expect(limiter.checkAndIncrement('id2'), isNull); // id2 untouched
    });

    test('resets after the window elapses', () async {
      final limiter = SlidingWindowLimiter(
          maxRequests: 1, window: const Duration(milliseconds: 50));
      expect(limiter.checkAndIncrement('id1'), isNull);
      expect(limiter.checkAndIncrement('id1'), isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(limiter.checkAndIncrement('id1'), isNull);
    });

    test('sweepExpired removes long-stale entries without affecting fresh ones',
        () async {
      final limiter = SlidingWindowLimiter(
          maxRequests: 5, window: const Duration(milliseconds: 20));
      limiter.checkAndIncrement('stale');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      limiter.checkAndIncrement('fresh');
      limiter.sweepExpired();
      // 'fresh' ka bucket abhi zinda hona chahiye (limit se bahut door),
      // 'stale' wala clean ho chuka hoga — dono ka indirect asar: 'fresh'
      // par 4 aur requests allowed honi chahiye (5 ki limit, 1 already ho
      // chuki).
      for (var i = 0; i < 4; i++) {
        expect(limiter.checkAndIncrement('fresh'), isNull);
      }
    });
  });
}
