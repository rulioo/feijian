import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/transfer.dart';

/// An image message, drawn as a picture rather than as a file card — §6.3.
///
/// Only reachable once the bytes are here. An image still moving, or one that
/// failed, is the card's business: a thumbnail that is a quarter painted reads
/// as a corrupt photo, and the card already says "43%" and offers a cancel.
///
/// The file is decoded at a bounded width rather than at full size. A chat
/// scrolled back through a holiday's worth of phone photos would otherwise hold
/// every one of them in memory at 12 megapixels, and `cacheWidth` is the one
/// line that stops it — the decoder scales on the way out of the codec instead
/// of after.
class AttachmentImage extends StatelessWidget {
  const AttachmentImage({
    required this.attachment,
    required this.onTap,
    this.fallback,
    super.key,
  });

  final Attachment attachment;

  /// Opens the fullscreen viewer.
  final VoidCallback onTap;

  /// Drawn when the bytes cannot be read — a file the user deleted from the
  /// folder by hand, or one on a volume that is no longer mounted. Null when the
  /// caller has nothing better to show, which leaves the broken-image glyph.
  final Widget? fallback;

  /// The widest a thumbnail is decoded at before the viewer scales it.
  ///
  /// 1024 covers a 520-logical-pixel bubble on a 2x screen with room to spare,
  /// and it caps what one photo costs at about 4 MB of decoded pixels instead of
  /// the 40 a modern phone camera would take.
  static const int _decodeWidth = 1024;

  /// The box the thumbnail occupies in the conversation.
  static const double _maxSide = 260;

  @override
  Widget build(BuildContext context) {
    final String? path = attachment.localPath;
    if (path == null) {
      return fallback ?? const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: _maxSide,
            maxHeight: _maxSide,
          ),
          child: Image.file(
            File(path),
            cacheWidth: _decodeWidth,
            // `cover` rather than `contain`: a portrait photo in a landscape box
            // letterboxes into two grey bars at a size that makes the picture
            // itself hard to judge, and the viewer is one tap away for anyone
            // who wants the whole frame.
            fit: BoxFit.cover,
            errorBuilder: (BuildContext context, Object _, StackTrace? __) =>
                fallback ?? const _BrokenImage(),
          ),
        ),
      ),
    );
  }
}

/// What an unreadable image looks like.
///
/// A visible placeholder rather than an empty box: the message is still in the
/// history, and a bubble that collapsed to nothing would read as a rendering
/// bug rather than as a file that is no longer there.
class _BrokenImage extends StatelessWidget {
  const _BrokenImage();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Container(
      width: 160,
      height: 100,
      color: scheme.surfaceContainerHighest,
      child: Icon(
        Icons.broken_image_outlined,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
