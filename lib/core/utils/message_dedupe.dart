import 'dart:collection';

import '../constants.dart';

/// Remembers which message ids have already been handled — design.md §4.5.
///
/// A sender re-sends a message it has no ack for, and re-sends it again after a
/// reconnect, so the same `msgId` legitimately arrives more than once. The
/// receiver drops the repeats; without this, one message shows up as two.
///
/// Bounded on purpose. An unbounded set is a slow memory leak on a long-lived
/// connection, and the ids it would have to remember to be wrong are far older
/// than any retry window (§4.5 retries for 30s at most).
class MessageDedupe {
  MessageDedupe({this.capacity = kMsgDedupeWindow})
    : assert(capacity > 0, 'a dedupe window of zero drops nothing');

  /// How many ids to remember. The oldest is evicted past this.
  final int capacity;

  /// Insertion-ordered, so the first key is the oldest eviction candidate.
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();

  int get length => _seen.length;

  /// Whether [msgId] is one that has not been handled before.
  ///
  /// Records the id as a side effect, in both cases: calling this twice with
  /// the same id answers true and then false. That is the whole contract — the
  /// second delivery is the one to discard — so there is no separate record
  /// step to forget to call.
  bool isNew(String msgId) {
    if (_seen.remove(msgId)) {
      // Already known. Re-inserting moves it to the end, so a message that
      // keeps being re-sent is not evicted while the retries are still coming.
      _seen.add(msgId);
      return false;
    }

    _seen.add(msgId);
    if (_seen.length > capacity) {
      _seen.remove(_seen.first);
    }
    return true;
  }

  /// Forgets everything. Used when a conversation is cleared, so that a
  /// still-retrying sender can deliver its message again rather than having it
  /// silently dropped as a repeat.
  void clear() => _seen.clear();
}
