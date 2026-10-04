import 'package:drift/drift.dart';
import 'package:feijian/data/dao/message_dao.dart';
import 'package:feijian/data/database.dart';

import '../../core/models/message.dart';

/// The chat history — design.md §5.1 `message`/`conversation`, §5.2 the queue.
///
/// Owns the transaction that the two DAOs were split apart for: a message is
/// never stored without the conversation summary that goes with it. It also owns
/// the conversion to [Message], so the state layer never touches a row.
///
/// Every method takes or returns domain types with `DateTime` timestamps, and
/// converts to the epoch milliseconds the tables store at the boundary. Doing
/// that in one place is what keeps the "whose clock is this" rule of §4.5
/// reviewable: nothing above this file sees a raw integer timestamp.
class ChatRepository {
  ChatRepository(this._db, {DateTime Function()? clock})
      : _messages = MessageDao(_db),
        _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final MessageDao _messages;

  /// The clock this repository reaches for itself, rather than being handed one
  /// per call the way every other write here is.
  ///
  /// [setDraft] is the one write the app originates with no message behind it, so
  /// there is no caller with a timestamp to pass — and the conversation row it
  /// may have to create wants a creation time. Injectable for the same reason
  /// `LanService`'s is: a test that asserts on a stored time should not depend on
  /// when it ran.
  final DateTime Function() _clock;

  // --- Reading --------------------------------------------------------------

  /// One page of history, newest first — the order the chat list consumes.
  ///
  /// [before] is the oldest message the caller already holds; pass null for the
  /// first page. The UI reverses it for a top-to-bottom view.
  Future<List<Message>> page(
    String peerId, {
    MessageCursor? before,
    int limit = kPageSize,
  }) async {
    final List<MessageRow> rows = await _messages.page(
      MessageDao.conversationIdFor(peerId),
      before: before,
      limit: limit,
    );
    return rows.map(_toMessage).toList();
  }

  /// The newest message in a conversation, for the device-list preview.
  Future<Message?> lastMessage(String peerId) async {
    final List<MessageRow> rows =
        await _messages.page(MessageDao.conversationIdFor(peerId), limit: 1);
    return rows.isEmpty ? null : _toMessage(rows.first);
  }

  /// Messages still owed to [peerId], oldest first — the §5.2 resend queue.
  ///
  /// Read from the database rather than kept in memory, so a message queued
  /// before the app was closed is still owed after it reopens (§5.2 item 6).
  Future<List<Message>> pendingFor(String peerId) async {
    final List<MessageRow> rows = await _messages.pendingFor(peerId);
    return rows.map(_toMessage).toList();
  }

  /// Every message still owed to anyone, oldest first.
  ///
  /// For the sweep after a restart: at that point nothing is connected yet, so
  /// the queue is rebuilt per peer rather than for one conversation.
  Future<List<Message>> allPending() async {
    final List<MessageRow> rows = await _messages.allPending();
    return rows.map(_toMessage).toList();
  }

  Future<int> unreadCount(String peerId) async {
    final ConversationRow? row =
        await _messages.conversationFor(peerId);
    return row?.unreadCount ?? 0;
  }

  /// Unread counts for every conversation, for the badges on the device list.
  ///
  /// Peers with nothing unread are included with a count of zero: the map is
  /// what the list looks up per tile, and an absent entry and a zero would be
  /// two ways of saying the same thing.
  Future<Map<String, int>> unreadByPeer() async {
    final List<ConversationRow> rows = await _messages.conversations();
    return <String, int>{
      for (final ConversationRow row in rows) row.peerId: row.unreadCount,
    };
  }

  Future<void> markRead(String peerId) =>
      _messages.markRead(MessageDao.conversationIdFor(peerId));

  Future<String?> draftFor(String peerId) async {
    final ConversationRow? row = await _messages.conversationFor(peerId);
    return row?.draft;
  }

  /// Remembers what is being typed, so switching devices does not lose it.
  ///
  /// Clears it when [draft] is empty — an empty draft is no draft, and storing
  /// one would put an empty string back in the composer where `null` puts
  /// nothing.
  Future<void> setDraft(String peerId, String? draft) {
    return _messages.setDraft(
      peerId,
      (draft == null || draft.isEmpty) ? null : draft,
      now: _clock().millisecondsSinceEpoch,
    );
  }

  /// The cursor to pass as [page]'s `before` to fetch the page older than
  /// [loaded], a newest-first page the caller already has.
  ///
  /// The oldest message of the page, not the newest: the cursor names the
  /// boundary to continue *past*, and using the newest would return the page the
  /// caller already holds, forever. A `DateTime` is converted back to the epoch
  /// milliseconds the column stores here rather than at each call site.
  static MessageCursor? cursorBefore(List<Message> loaded) {
    if (loaded.isEmpty) {
      return null;
    }
    final Message oldest = loaded.last;
    return MessageCursor(
      createdAt: oldest.createdAt.millisecondsSinceEpoch,
      id: oldest.id,
    );
  }

  // --- Writing --------------------------------------------------------------

  /// Stores a message this device is sending.
  ///
  /// Written as `pending` and returned immediately: §4.4.1 measured a failed
  /// connect at ~2 seconds on Windows, so the send path must not wait on the
  /// network — the message is durable first, and delivery is the queue's job.
  ///
  /// The insert and the conversation bump are one transaction because a message
  /// whose conversation never learned about it sorts the device list by a
  /// timestamp that does not advance, and the unread badge ends up wrong.
  Future<Message> saveOutgoing({
    required String msgId,
    required String peerId,
    required String text,
    MessageType type = MessageType.text,
    required DateTime now,
  }) async {
    final int at = now.millisecondsSinceEpoch;
    late int created;
    await _db.transaction(() async {
      final ConversationRow conversation =
          await _messages.ensureConversation(peerId, now: at);
      created = _orderedAt(conversation, at);
      await _messages.insertMessage(MessagesCompanion.insert(
        id: msgId,
        conversationId: conversation.id,
        peerId: peerId,
        direction: MessageDirection.outgoing.wire,
        type: type.wire,
        body: Value<String?>(text),
        status: MessageStatus.pending.wire,
        createdAt: created,
      ));
      await _messages.bumpConversation(conversation.id, lastMsgAt: created);
    });

    return Message(
      id: msgId,
      peerId: peerId,
      direction: MessageDirection.outgoing,
      type: type,
      text: text,
      status: MessageStatus.pending,
      createdAt: DateTime.fromMillisecondsSinceEpoch(created),
    );
  }

  /// Stores a message that arrived from [peerId], reporting whether it is new.
  ///
  /// False means a row with this id was already here — the peer re-sent
  /// something we have, which §4.5 makes normal rather than exceptional. **The
  /// caller must acknowledge it either way**: the peer is retrying precisely
  /// because it never saw an ack, and dropping the second copy silently would
  /// leave it retrying until it gave up.
  ///
  /// A duplicate also skips the conversation bump, so a message resent three
  /// times raises the unread badge once.
  Future<bool> storeIncoming({
    required String msgId,
    required String peerId,
    String? text,
    MessageType type = MessageType.text,
    required DateTime now,
  }) async {
    final int at = now.millisecondsSinceEpoch;
    return _db.transaction(() async {
      final ConversationRow conversation =
          await _messages.ensureConversation(peerId, now: at);
      final int created = _orderedAt(conversation, at);
      final bool isNew = await _messages.insertMessage(MessagesCompanion.insert(
        id: msgId,
        conversationId: conversation.id,
        peerId: peerId,
        direction: MessageDirection.incoming.wire,
        type: type.wire,
        body: Value<String?>(text),
        status: MessageStatus.received.wire,
        createdAt: created,
      ));
      if (isNew) {
        await _messages.bumpConversation(
          conversation.id,
          lastMsgAt: created,
          unread: true,
        );
      }
      return isNew;
    });
  }

  /// The `created_at` a new message in [conversation] gets: [at], pushed past
  /// the newest timestamp the conversation already holds.
  ///
  /// Without this, two messages written in the same millisecond have **no
  /// defined order**. `created_at` is a millisecond, and both orderings that
  /// read it break the tie on `id` — a random v4 UUID. So `pendingFor` sent a
  /// queue in a different order each run, and `page` displayed whatever order
  /// the UUIDs happened to compare in. That is not theoretical: the §5.2 test
  /// for flush order failed about one run in six, with the three messages
  /// arriving in a different order each time, and the flush is the worst case
  /// rather than a rare one — a queue that comes out all at once writes three
  /// messages inside a single millisecond. On the receiving side the same
  /// collision happens whenever a burst arrives, since an incoming message is
  /// stamped with the *receiver's* clock (§4.5).
  ///
  /// The fix belongs here rather than in the two `order by` clauses because the
  /// orderings are also used as keyset cursors (see [MessageDao.page]), where a
  /// tiebreaker has to be a value the caller can carry — and a monotonic
  /// timestamp keeps every existing query and cursor correct as they are.
  ///
  /// [conversation.lastMsgAt] is the previous maximum: [MessageDao.bumpConversation]
  /// only ever moves it forward and every insert passes its own timestamp, so it
  /// is the maximum over the conversation's messages, and reading it costs a
  /// primary-key lookup rather than a scan.
  ///
  /// Both callers run this inside the transaction that does the insert. That is
  /// load-bearing: it is what stops two concurrent writes from reading the same
  /// maximum and colliding again. Drift serializes transactions, so the second
  /// one sees the first one's commit.
  ///
  /// The timestamp can therefore run slightly ahead of the wall clock — by one
  /// millisecond per message in a burst. That is the standard trade a chat log
  /// makes, and it is bounded by the burst size: it cannot drift without
  /// messages to justify it.
  int _orderedAt(ConversationRow conversation, int at) {
    final int? newest = conversation.lastMsgAt;
    return newest == null || at > newest ? at : newest + 1;
  }

  /// Moves a message along its delivery state machine (§4.5).
  ///
  /// Returns whether the row changed. A refusal is expected, not an error: a
  /// resend's timeout firing just after the ack arrived would otherwise report a
  /// delivered message as merely sent (see `MessageDao.setStatus`).
  Future<bool> setStatus(
    String msgId,
    MessageStatus status, {
    DateTime? deliveredAt,
    int? retryCount,
  }) async {
    final int rows = await _messages.setStatus(
      msgId,
      status.wire,
      deliveredAt: deliveredAt?.millisecondsSinceEpoch,
      retryCount: retryCount,
    );
    return rows > 0;
  }

  /// Puts a failed message back in the queue for another attempt.
  ///
  /// Resets the retry count, because the user asking for a retry is a fresh
  /// decision rather than a continuation of the automatic attempts — otherwise
  /// a message that already burned `kMsgMaxRetries` would be marked failed
  /// again before it was ever sent.
  Future<bool> requeue(String msgId) =>
      setStatus(msgId, MessageStatus.pending, retryCount: 0);

  /// Deletes one message from this device only — §6.3's 「删除本地记录」.
  ///
  /// The peer keeps its copy, and nothing is sent to tell it otherwise. That is
  /// what "local record" means, and it is why the menu item is worded that way
  /// rather than "delete".
  Future<int> deleteMessage(String msgId) => _messages.deleteById(msgId);

  /// Deletes a whole conversation's messages, from this device only.
  ///
  /// The `conversation` row survives so the device stays in the list with its
  /// draft intact; see [MessageDao.clearIn] for why.
  ///
  /// Wrapped here rather than in the DAO, the same way [saveOutgoing] and
  /// [storeIncoming] are: deleting the messages and resetting the summary are
  /// one act, and a crash between them would leave a conversation that previews
  /// a message it no longer holds.
  Future<int> clearHistory(String peerId) {
    return _db.transaction(
      () => _messages.clearIn(MessageDao.conversationIdFor(peerId)),
    );
  }

  /// How many messages a page holds. Design §6.3.
  static const int kPageSize = 50;
}

Message _toMessage(MessageRow row) {
  return Message(
    id: row.id,
    peerId: row.peerId,
    direction: MessageDirection.fromWire(row.direction),
    type: MessageType.fromWire(row.type),
    text: row.body,
    status: MessageStatus.fromWire(row.status),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    deliveredAt: row.deliveredAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row.deliveredAt!),
    retryCount: row.retryCount,
  );
}
