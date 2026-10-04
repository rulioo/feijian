import 'package:drift/drift.dart';

import '../database.dart';

/// A position in a conversation's history, for paging — design.md §6.3.
///
/// `(createdAt, id)` rather than an offset, because messages keep arriving while
/// the user scrolls: with `LIMIT/OFFSET` a new message shifts every later row by
/// one and the next page repeats a message the user has already read. A cursor
/// names a position that does not move.
///
/// The pair matches `Message.compareOldestFirst` in `core/models/message.dart`,
/// so the order the database returns and the order the UI sorts into agree even
/// when two messages share a millisecond.
class MessageCursor {
  const MessageCursor({required this.createdAt, required this.id});

  final int createdAt;
  final String id;
}

/// Reads and writes the `message` and `conversation` tables — design.md §5.1.
///
/// The two are one DAO because every operation on one needs the other: storing a
/// message updates the conversation's `last_msg_at` and `unread_count`, and a
/// conversation is only ever created in order to hold messages. Splitting them
/// would mean a transaction spanning two objects at every call site.
class MessageDao {
  MessageDao(this._db);

  final AppDatabase _db;

  // --- Conversations --------------------------------------------------------

  /// Returns the conversation with [peerId], creating it if this is the first
  /// message either way.
  ///
  /// The conversation id is derived from the peer id so that two devices can
  /// never disagree about which conversation they are in — the wire carries no
  /// conversation id at all, only the peer.
  Future<ConversationRow> ensureConversation(
    String peerId, {
    required int now,
  }) async {
    final ConversationRow? existing = await conversationFor(peerId);
    if (existing != null) {
      return existing;
    }
    await _db.into(_db.conversations).insert(
          ConversationsCompanion.insert(
            id: conversationIdFor(peerId),
            peerId: peerId,
            createdAt: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    // Re-read rather than returning the row just built: a concurrent call may
    // have won the race, and whichever row is actually in the table is the one
    // the rest of the app will join against.
    return (await conversationFor(peerId))!;
  }

  static String conversationIdFor(String peerId) => 'conv:$peerId';

  Future<ConversationRow?> conversationFor(String peerId) {
    return (_db.select(_db.conversations)
          ..where((Conversations t) => t.peerId.equals(peerId)))
        .getSingleOrNull();
  }

  Future<ConversationRow?> conversationById(String id) {
    return (_db.select(_db.conversations)
          ..where((Conversations t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// All conversations with any local state, newest activity first.
  Future<List<ConversationRow>> conversations() {
    return (_db.select(_db.conversations)
          ..orderBy(<OrderingTerm Function(Conversations)>[
            (Conversations t) => OrderingTerm.desc(t.lastMsgAt),
          ]))
        .get();
  }

  Future<void> markRead(String conversationId) {
    return (_db.update(_db.conversations)
          ..where((Conversations t) => t.id.equals(conversationId)))
        .write(const ConversationsCompanion(unreadCount: Value<int>(0)));
  }

  /// Refreshes the conversation summary after a message lands.
  ///
  /// Separate from [insertMessage] so the caller can wrap both in one
  /// transaction: a message stored with the conversation's `last_msg_at` left
  /// behind would sort the device list by a timestamp that never advances, and
  /// the two writes failing apart would leave the unread badge wrong.
  ///
  /// [lastMsgAt] only ever moves forward, so a message inserted late with an
  /// older timestamp — an offline queue flushing after a reconnect, exactly the
  /// case §5.2 describes — cannot drag the conversation back down the list.
  Future<void> bumpConversation(
    String conversationId, {
    required int lastMsgAt,
    bool unread = false,
  }) async {
    final ConversationRow? current = await conversationById(conversationId);
    if (current == null) {
      return;
    }
    final int? previous = current.lastMsgAt;
    await (_db.update(_db.conversations)
          ..where((Conversations t) => t.id.equals(conversationId)))
        .write(ConversationsCompanion(
      lastMsgAt: Value<int>(
        previous == null || lastMsgAt > previous ? lastMsgAt : previous,
      ),
      unreadCount: unread
          ? Value<int>(current.unreadCount + 1)
          : const Value<int>.absent(),
    ));
  }

  /// Remembers what the user has typed but not sent.
  ///
  /// Creates the conversation first, if this is the first thing either side has
  /// written. That is not an edge case: a draft on a device nobody has messaged
  /// yet is what typing the opening message to a newly discovered device looks
  /// like, and a plain `UPDATE` against a row that does not exist yet changes
  /// nothing and reports success — so the text would be gone the moment the user
  /// looked at another conversation and came back.
  Future<void> setDraft(
    String peerId,
    String? draft, {
    required int now,
  }) async {
    await ensureConversation(peerId, now: now);
    await (_db.update(_db.conversations)
          ..where((Conversations t) => t.peerId.equals(peerId)))
        .write(ConversationsCompanion(draft: Value<String?>(draft)));
  }

  // --- Messages -------------------------------------------------------------

  /// Stores a message, reporting whether it is new to us.
  ///
  /// False means a row with this id was already there — the peer re-sent a
  /// message we have. That is the normal outcome of the retry in §4.5, not an
  /// error, and the caller must still acknowledge the message: the sender is
  /// retrying precisely because it never saw an ack.
  ///
  /// `insertOrIgnore` against the primary key, rather than a read-then-write,
  /// because two copies can arrive back to back on the same connection and a
  /// check-then-insert would let both through.
  Future<bool> insertMessage(MessagesCompanion message) async {
    final MessageRow? inserted = await _db
        .into(_db.messages)
        .insertReturningOrNull(message, mode: InsertMode.insertOrIgnore);
    return inserted != null;
  }

  Future<MessageRow?> byId(String id) {
    return (_db.select(_db.messages)..where((Messages t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// One page of a conversation, newest first, as the chat list displays it.
  ///
  /// [before] is the oldest message the caller already has; pass null for the
  /// first page. The caller reverses the result for a top-to-bottom chat view.
  Future<List<MessageRow>> page(
    String conversationId, {
    MessageCursor? before,
    int limit = 50,
  }) {
    final Expression<bool> scope =
        _db.messages.conversationId.equals(conversationId);
    return (_db.select(_db.messages)
          ..where((Messages t) => before == null
              ? scope
              : scope &
                  (t.createdAt.isSmallerThanValue(before.createdAt) |
                      (t.createdAt.equals(before.createdAt) &
                          t.id.isSmallerThanValue(before.id))))
          ..orderBy(<OrderingTerm Function(Messages)>[
            (Messages t) => OrderingTerm.desc(t.createdAt),
            // The tie-break, and it has to be here: without it two messages
            // sharing a millisecond come back in whatever order SQLite feels
            // like, so a page boundary could show one of them twice and drop
            // the other.
            (Messages t) => OrderingTerm.desc(t.id),
          ])
          ..limit(limit))
        .get();
  }

  /// Messages still owed to [peerId], oldest first — the offline queue of §5.2.
  ///
  /// Read from the database rather than an in-memory queue so that messages
  /// queued before the app was closed are still sent after it is reopened
  /// (§5.2 item 6). Ordered oldest-first because that is the order they are to
  /// be re-sent in, which is also the order they read in.
  Future<List<MessageRow>> pendingFor(String peerId) {
    return (_db.select(_db.messages)
          ..where((Messages t) =>
              t.peerId.equals(peerId) &
              t.status.equals('pending') &
              t.direction.equals('out'))
          ..orderBy(<OrderingTerm Function(Messages)>[
            (Messages t) => OrderingTerm.asc(t.createdAt),
            (Messages t) => OrderingTerm.asc(t.id),
          ]))
        .get();
  }

  /// Every message still owed to anyone, for the sweep after a restart.
  Future<List<MessageRow>> allPending() {
    return (_db.select(_db.messages)
          ..where((Messages t) =>
              t.status.equals('pending') & t.direction.equals('out'))
          ..orderBy(<OrderingTerm Function(Messages)>[
            (Messages t) => OrderingTerm.asc(t.createdAt),
          ]))
        .get();
  }

  /// Moves a message along its delivery state machine (§4.5).
  ///
  /// Writing `sent` is refused once the row says `delivered`. Acks and retry
  /// timeouts race by nature — the ack can arrive while a resend is being
  /// written — and without the guard the later `sent` write wins and the UI
  /// shows a single tick for a message that was confirmed. The other direction
  /// is deliberately allowed: a late ack for a message already marked `failed`
  /// is the truth, and §4.5's state machine has no way back except that one.
  Future<int> setStatus(
    String id,
    String status, {
    int? deliveredAt,
    int? retryCount,
  }) {
    final update = _db.update(_db.messages)
      ..where((Messages t) =>
          status == 'sent'
              ? t.id.equals(id) & t.status.equals('delivered').not()
              : t.id.equals(id));

    return update.write(MessagesCompanion(
      status: Value<String>(status),
      // Absent rather than null when not supplied: nulling `delivered_at` on an
      // unrelated transition would erase when the message actually arrived.
      deliveredAt:
          deliveredAt == null ? const Value<int>.absent() : Value<int>(deliveredAt),
      retryCount:
          retryCount == null ? const Value<int>.absent() : Value<int>(retryCount),
    ));
  }

  Future<int> deleteById(String id) {
    return (_db.delete(_db.messages)..where((Messages t) => t.id.equals(id))).go();
  }

  /// Deletes every message in a conversation — design.md §6.3's "clear history".
  ///
  /// The `conversation` row itself survives, which is the part worth stating:
  /// its `draft` is text the user has typed and not sent, and it is on screen in
  /// the composer while this runs. Destroying the row would leave that text
  /// visible until the page was reopened and gone afterwards, with nothing to
  /// explain where it went. A draft is not history.
  ///
  /// `unread_count` goes to zero and `last_msg_at` to NULL, because both are
  /// summaries *of the messages*, and there are none left. Leaving `last_msg_at`
  /// set would keep the device list previewing a message the user just deleted.
  ///
  /// Attachments follow through `ON DELETE CASCADE` (§5.1), so this is also what
  /// stops an orphaned transfer row from outliving its message.
  ///
  /// Returns how many messages went, which the caller needs: a `pending` one is
  /// a debt to the peer (§5.2), and deleting it is how the user cancels it.
  Future<int> clearIn(String conversationId) async {
    final int removed = await (_db.delete(_db.messages)
          ..where((Messages t) => t.conversationId.equals(conversationId)))
        .go();
    await (_db.update(_db.conversations)
          ..where((Conversations t) => t.id.equals(conversationId)))
        .write(const ConversationsCompanion(
      lastMsgAt: Value<int?>(null),
      unreadCount: Value<int>(0),
    ));
    return removed;
  }

  Future<int> countIn(String conversationId) async {
    final Expression<int> tally = _db.messages.id.count();
    final TypedResult result = await (_db.selectOnly(_db.messages)
          ..addColumns(<Expression<Object>>[tally])
          ..where(_db.messages.conversationId.equals(conversationId)))
        .getSingle();
    return result.read(tally) ?? 0;
  }
}
