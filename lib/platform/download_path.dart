import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where received files land — design.md §7.1.
///
/// This is the one place that knows about platform storage differences, so the
/// transfer code in `core/` never has to.
///
/// TODO(M3): on Android this should route images/videos through MediaStore
/// into the system gallery (`Pictures/Feijian`) and everything else into the
/// public Downloads collection. The current fallback — app-private documents —
/// is correct but invisible to the user's file manager.
abstract final class DownloadPath {
  static const String folderName = 'Feijian';

  /// The directory received files are written to, creating it if needed.
  ///
  /// Falls back to the app documents directory when the platform reports no
  /// Downloads folder (Android returns null for [getDownloadsDirectory]).
  static Future<Directory> resolve() async {
    Directory base;
    try {
      base =
          await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
    } on Exception {
      base = await getApplicationDocumentsDirectory();
    }

    final Directory dir = Directory(
      '${base.path}${Platform.pathSeparator}$folderName',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// The same path, without touching the filesystem — for display in settings.
  static Future<String> displayPath() async {
    try {
      final Directory? base = await getDownloadsDirectory();
      if (base != null) {
        return '${base.path}${Platform.pathSeparator}$folderName';
      }
    } on Exception {
      // Fall through to the documents directory below.
    }
    final Directory docs = await getApplicationDocumentsDirectory();
    return '${docs.path}${Platform.pathSeparator}$folderName';
  }
}
