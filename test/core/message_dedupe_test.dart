import 'package:feijian/core/constants.dart';
import 'package:feijian/core/utils/id.dart';
import 'package:feijian/core/utils/message_dedupe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageDedupe', () {
    test('answers true the first time and false after', () {
      final MessageDedupe dedupe = MessageDedupe();
      expect(dedupe.isNew('a'), isTrue);
      expect(dedupe.isNew('a'), isFalse);
      expect(dedupe.isNew('a'), isFalse);
      expect(dedupe.length, 1);
    });

    test('treats distinct ids as distinct', () {
      final MessageDedupe dedupe = MessageDedupe(capacity: 4);
      expect(dedupe.isNew('a'), isTrue);
      expect(dedupe.isNew('b'), isTrue);
      expect(dedupe.length, 2);
    });

    test('evicts the oldest once the window is full', () {
      final MessageDedupe dedupe = MessageDedupe(capacity: 3);
      dedupe.isNew('a');
      dedupe.isNew('b');
      dedupe.isNew('c');
      expect(dedupe.length, 3);

      dedupe.isNew('d');
      expect(dedupe.length, 3, reason: 'the window is a cap, not a tally');

      // 'a' was the oldest, so 'd' evicted it: a late duplicate of 'a' is
      // accepted again. That is the intended trade — the window is sized well
      // past the retry window, so it cannot happen while retries are live.
      expect(dedupe.isNew('a'), isTrue);
      // Re-adding 'a' then evicted 'b', which was the next oldest.
      expect(dedupe.isNew('c'), isFalse);
      expect(dedupe.isNew('d'), isFalse);
    });

    test('a repeat refreshes recency, so a still-retrying id survives', () {
      // The sender retries for 30s (§4.5). If a repeat did not refresh, a busy
      // conversation could evict an id that is still being re-sent, and the
      // retry would be stored a second time.
      final MessageDedupe dedupe = MessageDedupe(capacity: 3);
      dedupe.isNew('retrying');
      dedupe.isNew('b');
      dedupe.isNew('c');
      expect(dedupe.isNew('retrying'), isFalse); // refresh

      dedupe.isNew('d'); // evicts 'b', the oldest
      expect(dedupe.isNew('retrying'), isFalse);
      expect(dedupe.isNew('b'), isTrue, reason: 'b was evicted');
    });

    test('clear forgets everything', () {
      final MessageDedupe dedupe = MessageDedupe();
      dedupe.isNew('a');
      dedupe.clear();
      expect(dedupe.length, 0);
      expect(dedupe.isNew('a'), isTrue);
    });

    test('defaults to the configured window', () {
      final MessageDedupe dedupe = MessageDedupe();
      expect(dedupe.capacity, kMsgDedupeWindow);

      // At exactly `capacity` entries nothing has been evicted yet.
      for (int i = 0; i < kMsgDedupeWindow; i++) {
        dedupe.isNew('id-$i');
      }
      expect(dedupe.length, kMsgDedupeWindow);
      expect(dedupe.isNew('id-0'), isFalse);

      // That call refreshed 'id-0' to the newest, so the overflow now evicts
      // 'id-1' instead — and 'id-0', despite being the first ever seen, is
      // still remembered.
      dedupe.isNew('one-more');
      expect(dedupe.isNew('id-1'), isTrue);
      expect(dedupe.isNew('id-0'), isFalse);
    });

    test('a window of zero is rejected', () {
      expect(() => MessageDedupe(capacity: 0), throwsA(isA<AssertionError>()));
    });
  });

  group('newId', () {
    test('produces a different id every time', () {
      final Set<String> ids = <String>{
        for (int i = 0; i < 1000; i++) newId(),
      };
      expect(ids, hasLength(1000));
    });

    test('produces a well-formed UUIDv4', () {
      // Version 4 in the third group, variant bits in the fourth. Worth pinning
      // because a `msgId` is generated independently on every device and has to
      // be unique LAN-wide without coordination.
      expect(
        newId(),
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('fits the field limits the protocol enforces', () {
      expect(newId().length, lessThanOrEqualTo(kMaxDeviceIdLength));
    });
  });
}
