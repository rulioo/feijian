import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Publishes a received picture into the system gallery — Android only.
///
/// ## Why this exists
///
/// Received files land in the app's private documents directory — see
/// [DownloadPath] — which is correct and durable and completely invisible. The
/// picture is in the chat, and it is nowhere the user can reach it from: not in
/// Photos, not in a file manager, not available to any other app. Someone who
/// has just been sent a photo cannot set it as a wallpaper or forward it on,
/// which for a photo is most of what they wanted it for.
///
/// On Android the fix is MediaStore: publish a row under
/// `Pictures/<app>` and the gallery indexes it like a picture the camera took.
/// Since API 29 that needs no storage permission at all — writing through
/// MediaStore is the supported way to put a file in a shared collection, and it
/// is why this app asks for nothing.
///
/// ## Why the file is copied rather than moved
///
/// `attachment.localPath` is a real filesystem path, and five call sites depend
/// on that: `File(path).existsSync()` before opening, `File(from).copy(to)` for
/// save-as, `Image.file` for the thumbnail, `FileImage` for the full-screen
/// viewer, and `File(path).length()` to resume an interrupted transfer. A
/// `content://` URI in that column would break all five at once.
///
/// So the private copy stays the app's canonical one and the gallery gets a
/// second copy. The cost is that a received picture occupies twice its size,
/// which is a real cost and the reason it is written down here rather than
/// discovered later. The benefit is that the two are independent: deleting the
/// picture from the gallery does not leave a message in the chat that fails to
/// open when it is tapped.
///
/// Android only. Everywhere else this is a no-op answering false, so callers do
/// not have to branch.
abstract final class GallerySaver {
  static const MethodChannel _channel =
      MethodChannel('com.feijian.lan/gallery_saver');

  /// Copies the file at [path] into the gallery album and answers whether it
  /// arrived.
  ///
  /// [name] is the name the album shows, [mime] the concrete type the gallery
  /// needs to file it as a picture — see `Attachment.galleryMime`, which is
  /// where the caller gets it.
  ///
  /// Never throws. This is called on the receiving path of a transfer that has
  /// already succeeded: the bytes are on disk and the message says so, and a
  /// picture that could not be copied into the album is a smaller disappointment
  /// than a transfer reported as failed after it worked. False means the album
  /// did not get it, and the caller logs it and carries on.
  ///
  /// A name already in the album is not a failure — the platform appends a
  /// suffix rather than overwriting — so a false answer means the write itself
  /// went wrong, not that the name was taken.
  static Future<bool> save({
    required String path,
    required String name,
    required String? mime,
    void Function(String message)? onLog,
  }) async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final bool? saved = await _channel.invokeMethod<bool>('save', {
        'path': path,
        'name': name,
        'mime': mime,
      });
      if (saved != true) {
        onLog?.call('could not add $name to the gallery album');
      }
      return saved ?? false;
    } on Object catch (error) {
      onLog?.call('could not add $name to the gallery album: $error');
      debugPrint('[gallery-saver] save failed: $error');
      return false;
    }
  }
}
