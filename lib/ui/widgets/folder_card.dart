import 'package:flutter/material.dart';

import '../../core/models/transfer.dart';
import '../../l10n/app_localizations.dart';
import '../format.dart';
import 'attachment_card.dart';

/// The card a folder message shows instead of a file — design.md §6.3.
///
/// A folder is not one of its files and is not drawn through one: §4.6 makes it
/// a message and a *task* over many files, so the card counts instead of naming
/// — the design's `📁 Photos / 24 files · 156 MB / ████░░ 78%`.
///
/// Its two sources are deliberately separate, because they come from separate
/// places: [files] is the attachment rows, which exist from the moment the offer
/// is stored on either side, and [task] is the transfer row, which is the only
/// thing that knows how far the *folder* has got. A single file's card reads one
/// attachment because one attachment is the whole truth there; here neither is.
class FolderCard extends StatelessWidget {
  const FolderCard({
    required this.name,
    required this.files,
    required this.foreground,
    this.task,
    this.onOpen,
    this.onSaveAs,
    this.onCancel,
    this.onAccept,
    this.onDecline,
    super.key,
  });

  /// The folder's own name, which §5.1.1 keeps on the message rather than on any
  /// attachment — none of those describe the folder itself.
  final String name;

  /// The files inside, one row each. A directory carries no bytes and gets no
  /// row (§5.1.1), so an empty folder honestly has none.
  final List<Attachment> files;

  /// The bubble's foreground colour. Everything here is a shade of it.
  final Color foreground;

  /// The task behind this folder, or null when there is nothing live to show —
  /// a conversation reopened after the transfer ended.
  ///
  /// Nullable and not required: the row is read a page at a time, and a bubble
  /// that insisted on one would draw nothing at all in the moment before it
  /// arrives.
  final Transfer? task;

  /// Hand one of the finished files to the system. Null hides the button.
  final void Function(Attachment file)? onOpen;

  /// Copy one of the finished files somewhere the user chooses.
  final void Function(Attachment file)? onSaveAs;

  /// Stop the whole folder. Null hides the button.
  final VoidCallback? onCancel;

  /// The two answers to the offer, offered together or not at all.
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final TextStyle? nameStyle = theme.textTheme.bodyMedium?.copyWith(
      color: foreground,
      fontWeight: FontWeight.w500,
    );
    final TextStyle? detailStyle = theme.textTheme.labelSmall?.copyWith(
      color: foreground.withValues(alpha: 0.7),
    );

    final int total = files.fold(0, (int sum, Attachment f) => sum + f.size);
    final TransferState? state = task?.state;
    // The failures worth a line of their own. A file the user declined or
    // cancelled is not "missing" in a way that needs saying — the folder's own
    // state already says what happened to it.
    final int lost = files
        .where((Attachment f) => f.state == TransferState.failed)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.folder_outlined, size: 20, color: foreground),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                name,
                style: nameStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(l10n.folderFileCount(files.length), style: detailStyle),
            Text(' · ', style: detailStyle),
            Text(formatBytes(l10n, total), style: detailStyle),
            if (state != null) ...<Widget>[
              Text(' · ', style: detailStyle),
              Flexible(
                child: Text(
                  _status(l10n, state, task!),
                  style: detailStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
        if (_isMoving(state)) ...<Widget>[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              // The task's own fraction, not an attachment's: §4.6 gives one
              // `xferId` to the whole folder, and the card is about the folder.
              value: task!.progress,
              minHeight: 4,
              backgroundColor: foreground.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(foreground),
            ),
          ),
        ],
        if (lost > 0) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            l10n.folderSomeFilesFailed(lost),
            style: detailStyle?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        ..._files(context, l10n),
        ..._actions(l10n),
      ],
    );
  }

  /// The files that arrived, one row each with its own Open and Save as.
  ///
  /// Only the ones that are *here*: a folder of thirty files would otherwise
  /// draw thirty rows of which most are names the user cannot do anything with,
  /// and the file that landed is the one worth reaching for. A folder that
  /// arrived whole therefore lists everything, which is also what makes the
  /// listing worth having.
  List<Widget> _files(BuildContext context, AppLocalizations l10n) {
    final List<Attachment> here = files
        .where((Attachment f) => f.isOpenable)
        .toList(growable: false);
    if (here.isEmpty || (onOpen == null && onSaveAs == null)) {
      return const <Widget>[];
    }

    return <Widget>[
      const SizedBox(height: 2),
      // Capped rather than unbounded: a folder may hold a thousand files and a
      // bubble is a bubble. The rest are on disk and the count above says how
      // many; what is cut is a list, not a file.
      for (final Attachment file in here.take(_maxListed))
        _FileRow(
          file: file,
          foreground: foreground,
          onOpen: onOpen == null ? null : () => onOpen!(file),
          onSaveAs: onSaveAs == null ? null : () => onSaveAs!(file),
        ),
      if (here.length > _maxListed)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            l10n.folderMoreFiles(here.length - _maxListed),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: foreground.withValues(alpha: 0.7),
                ),
          ),
        ),
    ];
  }

  /// The buttons this state offers, and nothing else.
  ///
  /// The same rule as [AttachmentCard]'s, one level up: an offer is answered, a
  /// running folder is stopped, a finished one is opened file by file. Accepting
  /// a folder is one decision about the whole of it — §9.2 has no partial accept.
  List<Widget> _actions(AppLocalizations l10n) {
    final List<Widget> buttons = <Widget>[];
    if (onAccept != null || onDecline != null) {
      if (onDecline != null) {
        buttons.add(_CardButton(
          label: l10n.fileDecline,
          icon: Icons.close,
          foreground: foreground,
          onPressed: onDecline!,
        ));
      }
      if (onAccept != null) {
        buttons.add(_CardButton(
          label: l10n.fileAccept,
          icon: Icons.download_outlined,
          foreground: foreground,
          onPressed: onAccept!,
          emphasised: true,
        ));
      }
    }
    if (onCancel != null) {
      buttons.add(_CardButton(
        label: l10n.actionCancel,
        icon: Icons.cancel_outlined,
        foreground: foreground,
        onPressed: onCancel!,
      ));
    }

    if (buttons.isEmpty) {
      return const <Widget>[];
    }
    return <Widget>[
      const SizedBox(height: 6),
      Wrap(spacing: 4, runSpacing: 2, children: buttons),
    ];
  }

  /// How many of the folder's files the card names before it stops.
  static const int _maxListed = 5;

  /// Whether bytes are actively moving, so a bar means something.
  ///
  /// `pending` and `offered` are out, exactly as they are on a file's card:
  /// nothing has been agreed to, so a bar would sit at zero looking stuck.
  static bool _isMoving(TransferState? state) =>
      state == TransferState.transferring;

  /// The word for the task's state, with the one that needs a number.
  ///
  /// A folder's percentage is the *task's*, which is what §4.6's single
  /// `xferId` makes possible and what the design's wireframe shows. A file's
  /// card shows its own fraction because a file is all it has.
  static String _status(
    AppLocalizations l10n,
    TransferState state,
    Transfer task,
  ) {
    return switch (state) {
      TransferState.pending => l10n.transferWaiting,
      TransferState.offered => l10n.transferAwaitingAnswer,
      TransferState.transferring =>
        l10n.filePercent((task.progress * 100).round()),
      TransferState.done => l10n.transferDone,
      TransferState.failed => l10n.transferFailed,
      TransferState.cancelled => l10n.transferCancelled,
      TransferState.declined => l10n.transferDeclined,
    };
  }
}

/// One arrived file, as a line the user can act on.
///
/// Not an [AttachmentCard]: that card carries a state, a progress bar and a
/// Cancel, and every file in this list is in the same state — `done` — which is
/// the entry fee for being in it. Repeating the card would draw a finished
/// transfer's furniture once per file.
class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.foreground,
    this.onOpen,
    this.onSaveAs,
  });

  final Attachment file;
  final Color foreground;
  final VoidCallback? onOpen;
  final VoidCallback? onSaveAs;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.insert_drive_file_outlined, size: 14, color: foreground),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            file.fileName,
            style: theme.textTheme.labelSmall?.copyWith(color: foreground),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 4),
        // Icon buttons rather than the words: five rows of "Open  Save as..."
        // would be wider than the bubble and taller than the folder that earned
        // them. The tooltip carries the label the icon stands for.
        if (onOpen != null)
          IconButton(
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new, size: 15),
            color: foreground,
            tooltip: l10n.fileOpen,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        if (onSaveAs != null)
          IconButton(
            onPressed: onSaveAs,
            icon: const Icon(Icons.save_alt, size: 15),
            color: foreground,
            tooltip: l10n.fileSaveAs,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
      ],
    );
  }
}

/// One button on the card.
///
/// A copy of the file card's, which is private to it. Two cards that draw the
/// same button for the same reason is the point at which it stops being a
/// detail of either — but the alternative is a shared widget with a `foreground`
/// and an `emphasised` and two importers, which is what this already is.
class _CardButton extends StatelessWidget {
  const _CardButton({
    required this.label,
    required this.icon,
    required this.foreground,
    required this.onPressed,
    this.emphasised = false,
  });

  final String label;
  final IconData icon;
  final Color foreground;
  final VoidCallback onPressed;

  /// The one button the state is really about — Accept.
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final Color tint =
        emphasised ? foreground : foreground.withValues(alpha: 0.75);

    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: tint,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: Theme.of(context).textTheme.labelMedium,
        backgroundColor: emphasised ? foreground.withValues(alpha: 0.14) : null,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
    );
  }
}
