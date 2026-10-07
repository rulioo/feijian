import 'dart:io';

// `hide` because drift also exports `isNull`/`isNotNull` as query builders, and
// the matchers of the same name are what this test means by them.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/chat_repository.dart';
import 'package:flutter_test/flutter_test.dart';
// The v1 file has to be built by something that is not the current schema —
// that is the whole point of the test — so it is built by hand, by raw SQLite.
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// Opening a database written by an older build — design.md §5.1.
///
/// Every other test in this directory starts from `AppDatabase.memory()`, which
/// runs `onCreate` and never `onUpgrade`. That leaves the upgrade path — the one
/// real users travel, because their file was written by the previous release and
/// nobody is going to reinstall — as the single piece of the data layer with no
/// test at all. The v2 upgrade is a table rebuild, which is the kind of
/// migration that can silently drop rows; here it is checked on a real file with
/// a real row in it.
void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('feijian_migration_');
    file = File('${dir.path}${Platform.pathSeparator}feijian.sqlite');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// A database as **v1** wrote it: the same tables, except that `transfer`'s
  /// two foreign keys carry no action — which is exactly the shape that made
  /// deleting a file message fail.
  void writeV1() {
    final sqlite3.Database raw = sqlite3.sqlite3.open(file.path);
    raw.execute('''
      CREATE TABLE peer (
        id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL,
        device_type TEXT NOT NULL, icon TEXT NOT NULL, os TEXT,
        last_ip TEXT, last_port INTEGER, last_seen INTEGER,
        is_trusted INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE conversation (
        id TEXT NOT NULL PRIMARY KEY, peer_id TEXT NOT NULL UNIQUE,
        last_msg_at INTEGER, unread_count INTEGER NOT NULL DEFAULT 0,
        draft TEXT
      );
      CREATE TABLE message (
        id TEXT NOT NULL PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversation(id),
        peer_id TEXT NOT NULL, direction TEXT NOT NULL, type TEXT NOT NULL,
        text TEXT, status TEXT NOT NULL, created_at INTEGER NOT NULL,
        delivered_at INTEGER, retry_count INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX idx_message_conv
        ON message(conversation_id, created_at DESC);
      CREATE TABLE attachment (
        id TEXT NOT NULL PRIMARY KEY,
        message_id TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
        file_name TEXT NOT NULL, rel_path TEXT, size INTEGER NOT NULL,
        mime TEXT, local_path TEXT, thumb_path TEXT, sha256 TEXT,
        state TEXT NOT NULL, transferred INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE transfer (
        id TEXT NOT NULL PRIMARY KEY,
        message_id TEXT REFERENCES message(id),
        attachment_id TEXT REFERENCES attachment(id),
        peer_id TEXT NOT NULL, direction TEXT NOT NULL, state TEXT NOT NULL,
        bytes_done INTEGER NOT NULL DEFAULT 0, bytes_total INTEGER NOT NULL,
        temp_path TEXT, updated_at INTEGER NOT NULL
      );
      CREATE TABLE setting (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
    ''');
    raw.execute("INSERT INTO conversation (id, peer_id, unread_count) "
        "VALUES ('conv:p1', 'p1', 0)");
    raw.execute("INSERT INTO message (id, conversation_id, peer_id, direction, "
        "type, status, created_at) VALUES "
        "('m1', 'conv:p1', 'p1', 'out', 'image', 'sent', 1000)");
    raw.execute("INSERT INTO attachment (id, message_id, file_name, size, "
        "state, transferred) VALUES ('a1', 'm1', 'holiday.jpg', 4096, "
        "'done', 4096)");
    raw.execute("INSERT INTO transfer (id, message_id, attachment_id, peer_id, "
        "direction, state, bytes_done, bytes_total, updated_at) VALUES "
        "('xfer-1', 'm1', 'a1', 'p1', 'out', 'done', 4096, 4096, 1000)");
    raw.execute('PRAGMA user_version = 1');
    raw.dispose();
  }

  test('a v1 file opens as v2 and keeps its transfer', () async {
    writeV1();

    final AppDatabase db = AppDatabase.file(file);
    addTearDown(db.close);

    // The version is what the app compares before it decides to migrate at all,
    // so reading it back is the first thing worth doing.
    expect(await db.customSelect('PRAGMA user_version').getSingle()
        .then((QueryRow r) => r.read<int>('user_version')), 2);

    final List<TransferRow> rows = await db.select(db.transfers).get();
    expect(rows, hasLength(1), reason: 'the rebuild copies rows, it does not '
        'replace the table with an empty one');
    expect(rows.single.id, 'xfer-1');
    expect(rows.single.messageId, 'm1');
    expect(rows.single.attachmentId, 'a1');
    expect(rows.single.bytesDone, 4096, reason: 'every column comes across, '
        'not just the ones the migration was about');

    // And the point of the upgrade: the delete that used to be refused.
    final ChatRepository chat = ChatRepository(db);
    expect(await chat.deleteMessage('m1'), 1);
    expect(await db.select(db.transfers).get(), hasLength(1));
    expect(
      (await db.select(db.transfers).get()).single.messageId,
      isNull,
      reason: 'v2 is the version where the transfer lets go instead of '
          'holding the message hostage',
    );
  });

  test('a v1 file with no transfers upgrades just as well', () async {
    // The rebuild runs on an empty table too, and an empty `transfer` table is
    // the ordinary case for anyone who has only ever sent text.
    writeV1();
    final sqlite3.Database raw = sqlite3.sqlite3.open(file.path);
    raw.execute('DELETE FROM transfer');
    raw.dispose();

    final AppDatabase db = AppDatabase.file(file);
    addTearDown(db.close);

    expect(await db.select(db.transfers).get(), isEmpty);
    expect(await db.select(db.attachments).get(), hasLength(1));
  });

  test('a database created now is already at the current version', () async {
    // `onCreate` has to leave the file at the version `onUpgrade` migrates *to*,
    // or a fresh install would migrate itself on second launch.
    final AppDatabase db = AppDatabase.file(file);
    addTearDown(db.close);

    expect(await db.customSelect('PRAGMA user_version').getSingle()
        .then((QueryRow r) => r.read<int>('user_version')), db.schemaVersion);
  });
}
