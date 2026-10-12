import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where received files land — design.md §7.1.
///
/// This is the one place that knows about platform storage differences, so the
/// transfer code in `core/` never has to.
///
/// Every file still lands here, including pictures. Pictures are *additionally*
/// published to the system gallery under `Pictures/Feijian` by
/// [GallerySaver] — as a copy, not a move, because `attachment.localPath` has
/// to stay a real filesystem path. See that class for why.
///
/// TODO(M4): everything that is not a picture is still invisible to a file
/// manager. Android's Downloads collection (`MediaStore.Downloads`) is where a
/// received document belongs, and it needs no permission from API 29 either —
/// but it is a different collection with different rules, and a picture has to
/// stay out of it or every received photo lands in Downloads as well.
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
