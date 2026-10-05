import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Whatever is inside it, turned into a place files can be dropped — §6.3.
///
/// Only the paths are taken from the drop. What to do with them is [onFiles],
/// which is the same call the composer's paperclip makes: dropping a file and
/// picking it are two ways of answering one question, and they share the answer.
/// A second path from here to the engine would be a second place for the two to
/// drift apart.
///
/// The drop arrives from the platform rather than through Flutter's hit testing,
/// so this widget's bounds are the whole of what it covers — no `DragTarget`, no
/// hit-test entry. What that costs is on the desktop layout, where the device
/// list sits beside the conversation: a file dropped over the list lands on
/// nothing, because the list is asking a different question — *which* device —
/// and this is not the widget that knows the answer.
class DropRegion extends StatefulWidget {
  const DropRegion({required this.onFiles, required this.child, super.key});

  /// The absolute paths of what was dropped, in the order the platform gave
  /// them. Empty when a drag carries no files at all — a block of text, an image
  /// dragged out of a browser — and then there is nothing to send.
  final ValueChanged<List<String>> onFiles;

  final Widget child;

  @override
  State<DropRegion> createState() => _DropRegionState();
}

class _DropRegionState extends State<DropRegion> {
  /// Whether a drag is currently over this region, so the hint is showing.
  ///
  /// Cleared by the exit alone. A drop is the plugin putting the drag back to
  /// idle a moment before it hands the paths over —
  /// `_updateStatus(_DragTargetStatus.idle)` calls `onDragExited` and then
  /// `onDragDone` — so a drop is always preceded by the transition this listens
  /// for, and a second clear in `onDragDone` would be a line that can never do
  /// anything.
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (DropEventDetails _) => setState(() => _over = true),
      onDragExited: (DropEventDetails _) => setState(() => _over = false),
      onDragDone: (DropDoneDetails details) {
        widget.onFiles(<String>[
          for (final DropItem item in details.files) item.path,
        ]);
      },
      child: Stack(
        children: <Widget>[
          widget.child,
          // Not hit-testable: the drop is delivered by the platform rather than
          // by Flutter, so there is nothing under here for the overlay to
          // receive, and the conversation underneath should not be the thing
          // that stops responding for as long as a drag is in the air.
          if (_over)
            const Positioned.fill(child: IgnorePointer(child: _Hint())),
        ],
      ),
    );
  }
}

/// What covers the conversation while a file is over it.
///
/// A scrim rather than a border, because a border drawn inside a `Stack` would
/// be a four-pixel lie about where the region ends — the whole thing is the
/// target, including the composer at the bottom.
class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final Color accent = theme.colorScheme.primary;

    return ColoredBox(
      color: theme.colorScheme.surface.withValues(alpha: 0.88),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
          decoration: BoxDecoration(
            border: Border.all(color: accent, width: 2),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // Up, not down: the file is leaving this device.
              Icon(Icons.file_upload_outlined, size: 32, color: accent),
              const SizedBox(height: 8),
              Text(
                l10n.fileDropToSend,
                style: theme.textTheme.titleSmall?.copyWith(color: accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
