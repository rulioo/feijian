/// The SQLite schema — design.md §5.1.
///
/// Column names are spelled out with `.named()` where the obvious Dart name
/// would differ (`peer_id` → `peerId`), so the generated SQL matches the design
/// document exactly and can be compared against it by eye. Table names get the
/// same treatment by overriding `tableName`: drift would otherwise pluralise
/// the class (`Peers` → `peers`) and every name here would disagree with §5.1 by
/// one letter, which is the kind of thing nobody notices until they open the
/// file with `sqlite3` and find the queries in the design document do not run.
///
/// The whole v1 schema is defined now, including the two tables M2 does not use
/// yet, because adding a table later means a migration while adding a column
/// now is free. The tables carry no logic; the *code* for transfers still waits
/// for M3, as the pubspec's dependency comment describes.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

part 'database.g.dart';

/// Devices we have seen — design.md §5.1.
///
/// Rows survive going offline: the conversation history hanging off them would
/// otherwise be orphaned. A peer that has not announced for
/// `kPeerRemoveAfter` leaves the device *list*, not this table.
@DataClassName('PeerRow')
class Peers extends Table {
  @override
  String get tableName => 'peer';

  /// Device UUID, generated once on first install. The identity everything else
  /// is keyed on — never the name, which the user can change at any time.
  TextColumn get id => text()();

  TextColumn get name => text()();

  /// `windows` / `android` / `ios`. Stored as text rather than an int index so
  /// the file stays readable and a reordering of the enum cannot silently
  /// reinterpret every existing row.
  TextColumn get deviceType => text().named('device_type')();

  /// Free-form OS description, e.g. "Windows 11 23H2". Display only.
  TextColumn get os => text().nullable()();

  TextColumn get icon => text().nullable()();

  /// Optional custom avatar, uploaded by the peer.
  BlobColumn get avatar => blob().nullable()();

  TextColumn get lastIp => text().named('last_ip').nullable()();

  /// Milliseconds since the epoch.
  ///
  /// Deliberately nullable and advisory: it is the peer's own claim about when
  /// it announced, and §4.5 already establishes that a peer's clock is not to
  /// be trusted for anything that matters.
  IntColumn get lastSeen => integer().named('last_seen').nullable()();

  /// Trusted peers may auto-accept file offers (§6.4).
  BoolColumn get isTrusted =>
      boolean().named('is_trusted').withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One conversation per peer — design.md §5.1.
///
/// A separate table rather than fields on `peer` because unread counts and
/// drafts are local state: two devices talking to the same peer must not share
/// them, and a peer row is refreshed wholesale by every announce.
@DataClassName('ConversationRow')
class Conversations extends Table {
  @override
  String get tableName => 'conversation';

  TextColumn get id => text()();

  /// Deliberately *not* a foreign key, unlike §5.1's original draft.
  ///
  /// The `peer` table is a cache of what devices have announced about
  /// themselves; a conversation is the user's own data. Referencing one from the
  /// other makes forgetting a device — the one action that removes a peer row —
  /// either impossible (SQLite's default `NO ACTION` refuses the delete) or
  /// destructive (`ON DELETE CASCADE` would erase the history with it, with no
  /// undo, as a side effect of tidying a device list).
  ///
  /// `message.peer_id` below already has no reference, so a peer id with no peer
  /// row is a state this schema tolerates regardless; a constraint that only
  /// holds for one of the two tables would not even buy consistency.
  TextColumn get peerId => text().named('peer_id')();

  IntColumn get createdAt => integer().named('created_at')();

  /// Timestamp of the newest message, for sorting the device list by recency.
  IntColumn get lastMsgAt => integer().named('last_msg_at').nullable()();

  IntColumn get unreadCount =>
      integer().named('unread_count').withDefault(const Constant(0))();

  /// Unsent draft text, so switching devices does not lose what was typed.
  TextColumn get draft => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One message — design.md §5.1.
@DataClassName('MessageRow')
class Messages extends Table {
  @override
  String get tableName => 'message';

  /// The `msgId` from the wire, not a locally generated key.
  ///
  /// This is what makes a re-delivered message harmless: the sender reuses its
  /// `msgId` when it retries (§4.5), so a plain insert collides on the primary
  /// key and can be ignored rather than stored twice. The in-memory dedupe
  /// window covers the running session; this covers the restart the window
  /// cannot survive.
  TextColumn get id => text()();

  TextColumn get conversationId =>
      text().named('conversation_id').references(Conversations, #id)();

  TextColumn get peerId => text().named('peer_id')();

  /// `in` / `out`, from this device's point of view.
  TextColumn get direction => text()();

  /// `text` / `file` / `image` / `folder` / `system`.
  TextColumn get type => text()();

  /// The message body.
  ///
  /// The Dart accessor is `body` because a member named `text` would shadow the
  /// `text()` column builder from `Table` and make this declaration impossible
  /// to write. The SQL column stays `text`, as the design document has it.
  TextColumn get body => text().named('text').nullable()();

  /// `pending` / `sent` / `delivered` / `failed` / `received`.
  TextColumn get status => text()();

  /// This device's local clock, not the peer's. It is the sort key (§4.5), so
  /// it must never be something a remote clock can move.
  IntColumn get createdAt => integer().named('created_at')();

  IntColumn get deliveredAt => integer().named('delivered_at').nullable()();

  IntColumn get retryCount =>
      integer().named('retry_count').withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// A file attached to a message — design.md §5.1.
///
/// A list rather than a single file because a transferred folder is one message
/// with many attachments.
@DataClassName('AttachmentRow')
class Attachments extends Table {
  @override
  String get tableName => 'attachment';

  TextColumn get id => text()();

  TextColumn get messageId =>
      text().named('message_id').references(Messages, #id, onDelete: KeyAction.cascade)();

  TextColumn get fileName => text().named('file_name')();

  /// Path inside the transferred folder, for a folder transfer.
  TextColumn get relPath => text().named('rel_path').nullable()();

  IntColumn get size => integer()();

  TextColumn get mime => text().nullable()();

  /// Where the file ended up on this device once received.
  TextColumn get localPath => text().named('local_path').nullable()();

  /// Cached thumbnail, so the chat list does not decode full images.
  TextColumn get thumbPath => text().named('thumb_path').nullable()();

  TextColumn get sha256 => text().nullable()();

  /// `pending` / `downloading` / `done` / `failed` / `cancelled`.
  TextColumn get state => text()();

  IntColumn get transferred => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// A transfer in progress, so an interrupted one can resume — design.md §5.1.
@DataClassName('TransferRow')
class Transfers extends Table {
  @override
  String get tableName => 'transfer';

  /// The `xferId` from the wire.
  TextColumn get id => text()();

  TextColumn get messageId =>
      text().named('message_id').references(Messages, #id).nullable()();

  TextColumn get attachmentId =>
      text().named('attachment_id').references(Attachments, #id).nullable()();

  TextColumn get peerId => text().named('peer_id')();

  TextColumn get direction => text()();

  TextColumn get state => text()();

  IntColumn get bytesDone => integer().named('bytes_done').withDefault(const Constant(0))();

  IntColumn get bytesTotal => integer().named('bytes_total')();

  /// The partial file. Kept so a resumed transfer continues rather than
  /// restarting — which for a large file over Wi-Fi is the difference between a
  /// feature and a nuisance.
  TextColumn get tempPath => text().named('temp_path').nullable()();

  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Key/value settings — design.md §5.1.
///
/// Deliberately untyped text: the values are display name, icon choice, download
/// directory and so on, and wrapping each in its own column would mean a
/// migration per preference.
@DataClassName('SettingRow')
class Settings extends Table {
  @override
  String get tableName => 'setting';

  TextColumn get key => text()();

  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{key};
}

@DriftDatabase(
  tables: <Type>[Peers, Conversations, Messages, Attachments, Transfers, Settings],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// A throwaway database for tests and for the "reset everything" path.
  AppDatabase.memory() : super(NativeDatabase.memory());

  /// The real database on disk.
  ///
  /// `createInBackground` runs SQLite on its own isolate, which keeps a large
  /// query from janking the UI thread — the history of a long conversation is
  /// not small, and a synchronous open would also block startup.
  AppDatabase.file(File file) : super(NativeDatabase.createInBackground(file));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
          // Hand-written rather than `@TableIndex`, which cannot express the
          // DESC: this index exists to serve "the last page of a conversation",
          // and an ascending one would have to scan and reverse-sort.
          await customStatement(
            'CREATE INDEX idx_message_conv '
            'ON message(conversation_id, created_at DESC)',
          );
        },
        beforeOpen: (OpeningDetails details) async {
          // SQLite has foreign keys OFF by default, and an off switch turns
          // every `REFERENCES` above into decoration — including the cascade
          // that keeps attachments from outliving their message. Each
          // connection needs this, hence `beforeOpen` rather than `onCreate`.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
