import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Where the app's own files live.
///
/// One place, so the database and anything added later agree on the directory —
/// and so the file name is stated once rather than assembled at each call site
/// from a path separator that differs by platform.
abstract final class AppPaths {
  /// The support directory, not documents: this is app state the user has no
  /// reason to browse, and on iOS the documents directory is visible in Files
  /// while the support directory can be excluded from backups.
  static const String databaseFileName = 'feijian.sqlite';

  /// The history database.
  ///
  /// Created lazily by SQLite on first open, so this only resolves the path and
  /// does not need the directory to exist.
  ///
  /// A platform that reports no support directory falls back to the working
  /// directory rather than failing: messaging is this app's purpose, and one
  /// that refuses to start is worse than one whose history lands somewhere
  /// unexpected. The fallback is logged so the surprise is not silent.
  static Future<File> databaseFile() async {
    try {
      final Directory dir = await getApplicationSupportDirectory();
      return File('${dir.path}${Platform.pathSeparator}$databaseFileName');
    } on Object catch (error) {
      final String here =
          '${Directory.current.path}${Platform.pathSeparator}$databaseFileName';
      debugPrint('[app] no support directory ($error); using $here');
      return File(here);
    }
  }
}
