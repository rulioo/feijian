import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import '../../core/models/transfer.dart';
import '../../l10n/app_localizations.dart';

/// One image, full screen, zoomable — design.md §6.3.
///
/// A gallery rather than a single picture, because the conversation is the
/// context the user is in: §6.3 asks for swiping between the images of the same
/// conversation, and handing the page the whole run of them is what makes that
/// a `PageView` instead of a route that has to be popped and pushed to move one
/// photo along.
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    required this.images,
    required this.initialIndex,
    super.key,
  });

  /// Every image in the conversation, oldest first — the order the chat shows
  /// them in, so swiping moves the same way the list does.
  final List<Attachment> images;

  final int initialIndex;

  /// The route to push. Returns when the viewer is closed.
  static Route<void> route({
    required List<Attachment> images,
    required int initialIndex,
  }) {
    return MaterialPageRoute<void>(
      builder: (BuildContext context) =>
          ImageViewerPage(images: images, initialIndex: initialIndex),
    );
  }

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _current = widget.initialIndex;

  /// The chrome — the bar and its title — hides on tap, the way every photo
  /// viewer does it, so the picture can have the whole screen.
  bool _showChrome = true;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Attachment shown = widget.images[_current];

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _showChrome
          ? AppBar(
              backgroundColor: Colors.black.withValues(alpha: 0.4),
              foregroundColor: Colors.white,
              elevation: 0,
              title: Text(
                shown.fileName,
                style: const TextStyle(fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: l10n.close,
                onPressed: () => Navigator.of(context).pop(),
              ),
            )
          : null,
      body: GestureDetector(
        onTap: () => setState(() => _showChrome = !_showChrome),
        child: PhotoViewGallery.builder(
          pageController: _pages,
          itemCount: widget.images.length,
          // A background the picture sits on rather than a colour the gallery
          // paints: `PhotoViewGallery` needs one to scale against.
          backgroundDecoration: const BoxDecoration(color: Colors.black),
          onPageChanged: (int index) => setState(() => _current = index),
          builder: (BuildContext context, int index) {
            final Attachment attachment = widget.images[index];
            final String? path = attachment.localPath;

            if (path == null) {
              return PhotoViewGalleryPageOptions.customChild(
                child: const Center(
                  child: Icon(Icons.broken_image_outlined,
                      color: Colors.white54, size: 48),
                ),
                minScale: PhotoViewComputedScale.contained,
                maxScale: PhotoViewComputedScale.contained,
              );
            }

            return PhotoViewGalleryPageOptions(
              imageProvider: FileImage(File(path)),
              // `contained` as the floor, so a small image opens filling the
              // frame rather than as a postage stamp in the middle of it.
              initialScale: PhotoViewComputedScale.contained,
              minScale: PhotoViewComputedScale.contained,
              // 4x rather than unbounded: past that the pixels are gone and the
              // user is looking at interpolation, and a pinch that keeps going
              // forever is easy to get lost in.
              maxScale: PhotoViewComputedScale.covered * 4,
              heroAttributes: PhotoViewHeroAttributes(
                tag: 'attachment-${attachment.id}',
              ),
              errorBuilder: (BuildContext context, Object _, StackTrace? __) =>
                  const Center(
                child: Icon(Icons.broken_image_outlined,
                    color: Colors.white54, size: 48),
              ),
            );
          },
        ),
      ),
    );
  }
}
