import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

/// Runs once before every test under `test/` — Flutter's hook for exactly this.
///
/// The database tests need a native SQLite, and `flutter test` runs on the host
/// Dart VM where nothing provides one: `sqlite3_flutter_libs` copies the library
/// into a *built* app, which this project cannot produce yet. Windows ships its
/// own build at `C:\Windows\System32\winsqlite3.dll`, so the tests borrow that
/// instead of requiring a hand-downloaded DLL on every machine. It only changes
/// where the tests find the library — the app keeps using the bundled one.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open('winsqlite3.dll'),
    );
  }
  await testMain();
}
