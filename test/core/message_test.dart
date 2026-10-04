import 'package:feijian/core/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

Message msg(
  String id, {
  DateTime? at,
  MessageStatus status = MessageStatus.sent,
  MessageDirection direction = MessageDirection.outgoing,
  String peer = 'peer-1',
  String? text = 'hi',
}) {
  return Message(
    id: id,
    peerId: peer,
    direction: direction,
    type: MessageType.text,
    status: status,
    createdAt: at ?? DateTime(2026, 10, 4, 12),
    text: text,
  );
}

void main() {
  group('wire values round-trip through the database', () {
    test('direction', () {
      for (final MessageDirection d in MessageDirection.values) {
        expect(MessageDirection.fromWire(d.wire), d);
      }
    });

    test('type', () {
      for (final MessageType t in MessageType.values) {
        expect(MessageType.fromWire(t.wire), t);
      }
    });

    test('status', () {
      for (final MessageStatus s in MessageStatus.values) {
        expect(MessageStatus.fromWire(s.wire), s);
      }
    });

    test('an unrecognised value falls back rather than throwing', () {
      // A row written by a newer build must not crash this one on read.
      expect(MessageDirection.fromWire('sideways'), MessageDirection.incoming);
      expect(MessageType.fromWire('video'), MessageType.text);
      expect(MessageStatus.fromWire('read'), MessageStatus.pending);
    });
  });

  group('status helpers', () {
    test('pending and sent are not settled — they are still owed an attempt',
        () {
      expect(msg('a', status: MessageStatus.pending).isSettled, isFalse);
      expect(msg('a', status: MessageStatus.sent).isSettled, isFalse);
    });

    test('delivered, received and failed are settled', () {
      expect(msg('a', status: MessageStatus.delivered).isSettled, isTrue);
      expect(msg('a', status: MessageStatus.received).isSettled, isTrue);
      expect(msg('a', status: MessageStatus.failed).isSettled, isTrue);
    });

    test('only a failed message offers a retry', () {
      for (final MessageStatus s in MessageStatus.values) {
        expect(
          msg('a', status: s).canRetry,
          s == MessageStatus.failed,
          reason: '$s',
        );
      }
    });
  });

  group('copyWith', () {
    test('changes only what it is given', () {
      final Message original = msg('a', status: MessageStatus.sent);
      final Message updated =
          original.copyWith(status: MessageStatus.delivered, retryCount: 2);

      expect(updated.id, original.id);
      expect(updated.createdAt, original.createdAt);
      expect(updated.text, original.text);
      expect(updated.status, MessageStatus.delivered);
      expect(updated.retryCount, 2);
    });

    test('cannot change identity or time', () {
      // Deliberate: `id` is the dedupe key and `createdAt` is the sort key, so
      // rewriting either would silently corrupt history rather than update it.
      final Message updated = msg('a').copyWith(status: MessageStatus.failed);
      expect(updated.id, 'a');
      expect(updated.createdAt, msg('a').createdAt);
    });
  });

  group('equality', () {
    test('two messages with the same content are equal', () {
      expect(msg('a'), msg('a'));
      expect(msg('a').hashCode, msg('a').hashCode);
    });

    test('a different status is a different message', () {
      // The UI rebuilds on this: a bubble going from sent to delivered has to
      // be a new value or the tick never appears.
      expect(msg('a', status: MessageStatus.sent), isNot(msg('a', status: MessageStatus.delivered)));
    });
  });

  group('ordering (design.md §4.5)', () {
    test('oldest first sorts by time ascending', () {
      final List<Message> messages = <Message>[
        msg('c', at: DateTime(2026, 10, 4, 12, 2)),
        msg('a', at: DateTime(2026, 10, 4, 12, 0)),
        msg('b', at: DateTime(2026, 10, 4, 12, 1)),
      ]..sort(Message.compareOldestFirst);

      expect(messages.map((Message m) => m.id), <String>['a', 'b', 'c']);
    });

    test('newest first is exactly the reverse', () {
      // A page read newest-first and then reversed for display must come out in
      // the same order as one read oldest-first, or the list jumps when it
      // paginates.
      final List<Message> messages = <Message>[
        msg('c', at: DateTime(2026, 10, 4, 12, 2)),
        msg('a', at: DateTime(2026, 10, 4, 12, 0)),
        msg('b', at: DateTime(2026, 10, 4, 12, 1)),
      ];

      final List<String> oldestFirst = (List<Message>.of(messages)
            ..sort(Message.compareOldestFirst))
          .map((Message m) => m.id)
          .toList();
      final List<String> newestFirst = (List<Message>.of(messages)
            ..sort(Message.compareNewestFirst))
          .map((Message m) => m.id)
          .toList();

      expect(newestFirst, oldestFirst.reversed.toList());
    });

    test('messages sharing a millisecond get a stable order', () {
      // A burst flushed from the offline queue lands in one tick, so ties are
      // the normal case after a reconnect rather than a corner case.
      final DateTime same = DateTime(2026, 10, 4, 12);
      final List<Message> messages = <Message>[
        msg('zzz', at: same),
        msg('aaa', at: same),
        msg('mmm', at: same),
      ]..sort(Message.compareOldestFirst);

      expect(messages.map((Message m) => m.id), <String>['aaa', 'mmm', 'zzz']);
    });

    test('the comparator never reports two distinct messages as equal', () {
      // Returning 0 for a tie would let the displayed order depend on the input
      // order, which differs between a fresh query and a re-sorted page. This
      // is what makes ties resolve identically on both ends of the LAN.
      final DateTime same = DateTime(2026, 10, 4, 12);
      final List<Message> messages = <Message>[
        msg('b', at: same),
        msg('a', at: same),
        msg('c', at: same),
      ];

      for (final Message x in messages) {
        for (final Message y in messages) {
          if (x.id == y.id) {
            continue;
          }
          expect(Message.compareOldestFirst(x, y), isNot(0));
        }
      }
    });

    test('sorting is independent of input order', () {
      final List<Message> a = <Message>[
        msg('c', at: DateTime(2026, 10, 4, 12, 2)),
        msg('a', at: DateTime(2026, 10, 4, 12, 0)),
        msg('b', at: DateTime(2026, 10, 4, 12, 1)),
      ]..sort(Message.compareOldestFirst);
      final List<Message> b = <Message>[
        msg('b', at: DateTime(2026, 10, 4, 12, 1)),
        msg('c', at: DateTime(2026, 10, 4, 12, 2)),
        msg('a', at: DateTime(2026, 10, 4, 12, 0)),
      ]..sort(Message.compareOldestFirst);

      expect(a.map((Message m) => m.id), b.map((Message m) => m.id));
    });
  });
}
