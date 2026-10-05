import 'package:flutter/material.dart';

import '../../core/models/transfer.dart';
import '../../l10n/app_localizations.dart';
import '../format.dart';

/// The card a file message shows instead of text — design.md §6.3.
///
/// One widget for every state of one attachment, because the states differ by a
/// status line and which buttons are offered, and splitting them into a
/// "transferring card" and a "finished card" would duplicate the name, the icon
/// and the size — the three things that never change from the moment the offer
/// arrives to the moment the file is opened.
///
/// It draws on the bubble's background rather than carrying its own, so the
/// colours come in as [foreground] the way they do for [MessageBubble]'s text.
class AttachmentCard extends StatelessWidget {
  const AttachmentCard({
    required this.attachment,
    required this.foreground,
    this.onOpen,
    this.onSaveAs,
    this.onCancel,
    this.onAccept,
    this.onDecline,
    super.key,
  });

  final Attachment attachment;

  /// The bubble's foreground colour. Everything here is a shade of it.
  final Color foreground;

  /// Hand the finished file to the system. Null hides the button.
  final VoidCallback? onOpen;

  /// Copy the finished file somewhere the user chooses. Null hides the button.
  final VoidCallback? onSaveAs;

  /// Stop a transfer that is moving, or cancel one that has not started.
  final VoidCallback? onCancel;

  /// The two answers to an offer. Both are offered together or not at all.
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(_iconFor(attachment), size: 20, color: foreground),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                attachment.fileName,
                style: nameStyle,
                maxLines: 1,
                // The name is the thing the user is looking for, so it gets the
                // room; a full path or a very long name is still identifiable
                // from its beginning.
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(formatBytes(l10n, attachment.size), style: detailStyle),
            Text(' · ', style: detailStyle),
            Flexible(
              child: Text(
                _status(l10n, attachment),
                style: detailStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (_isMoving(attachment)) ...<Widget>[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: attachment.progress,
              minHeight: 4,
              backgroundColor: foreground.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(foreground),
            ),
          ),
        ],
        ..._actions(context),
      ],
    );
  }

  /// The buttons this state offers, and nothing else.
  ///
  /// An offer is answered, a running transfer is stopped, a finished file is
  /// opened. A card that offered all of them at once would let a user press
  /// "Open" on a file that is half here.
  List<Widget> _actions(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);

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
    } else {
      if (onOpen != null) {
        buttons.add(_CardButton(
          label: l10n.fileOpen,
          icon: Icons.open_in_new,
          foreground: foreground,
          onPressed: onOpen!,
          emphasised: true,
        ));
      }
      if (onSaveAs != null) {
        buttons.add(_CardButton(
          label: l10n.fileSaveAs,
          icon: Icons.save_alt,
          foreground: foreground,
          onPressed: onSaveAs!,
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
      // `Wrap`, not `Row`: three labels in a future locale will not fit the
      // 520-pixel cap the bubble imposes, and a `Row` would answer that with an
      // overflow stripe rather than a second line.
      Wrap(spacing: 4, runSpacing: 2, children: buttons),
    ];
  }

  /// Whether bytes are actively moving, so a bar means something.
  ///
  /// `pending` and `offered` are deliberately out: nothing has been agreed to,
  /// so a bar would be a bar over nothing, and it would sit at zero looking like
  /// a transfer that is stuck.
  static bool _isMoving(Attachment attachment) =>
      attachment.state == TransferState.transferring;

  static String _status(AppLocalizations l10n, Attachment attachment) {
    return switch (attachment.state) {
      TransferState.pending => l10n.transferWaiting,
      TransferState.offered => l10n.transferAwaitingAnswer,
      // A percentage rather than a word: the bar above already says which
      // direction it is going, and "Sending · 43%" says nothing more.
      TransferState.transferring =>
        l10n.filePercent((attachment.progress * 100).round()),
      TransferState.done => l10n.transferDone,
      TransferState.failed => l10n.transferFailed,
      TransferState.cancelled => l10n.transferCancelled,
      TransferState.declined => l10n.transferDeclined,
    };
  }

  /// An icon from the file's type, falling back to the name's extension.
  ///
  /// The mime type is what the *sender* claimed and is only set when the sender
  /// knew it; the extension is what is actually on the disk here, and it is what
  /// the user will see when they open the folder. Either is worth using, and
  /// they disagree often enough — a `.jpg` sent as `application/octet-stream` —
  /// that the fallback is not dead code.
  static IconData _iconFor(Attachment attachment) {
    final String? mime = attachment.mime?.toLowerCase();
    if (mime != null) {
      if (mime.startsWith('image/')) {
        return Icons.image_outlined;
      }
      if (mime.startsWith('video/')) {
        return Icons.movie_outlined;
      }
      if (mime.startsWith('audio/')) {
        return Icons.audiotrack_outlined;
      }
      if (mime.startsWith('text/')) {
        return Icons.description_outlined;
      }
      if (mime == 'application/pdf') {
        return Icons.picture_as_pdf_outlined;
      }
    }

    final int dot = attachment.fileName.lastIndexOf('.');
    final String ext =
        dot <= 0 ? '' : attachment.fileName.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'png' ||
      'jpg' ||
      'jpeg' ||
      'gif' ||
      'webp' ||
      'bmp' ||
      'heic' ||
      'svg' =>
        Icons.image_outlined,
      'mp4' || 'mov' || 'mkv' || 'avi' || 'webm' => Icons.movie_outlined,
      'mp3' || 'wav' || 'flac' || 'm4a' || 'ogg' => Icons.audiotrack_outlined,
      'pdf' => Icons.picture_as_pdf_outlined,
      'zip' ||
      'rar' ||
      '7z' ||
      'gz' ||
      'tar' ||
      'xz' =>
        Icons.folder_zip_outlined,
      'txt' ||
      'md' ||
      'log' ||
      'csv' ||
      'json' ||
      'xml' =>
        Icons.description_outlined,
      'doc' || 'docx' || 'odt' || 'rtf' => Icons.article_outlined,
      'xls' || 'xlsx' || 'ods' => Icons.table_chart_outlined,
      'ppt' || 'pptx' || 'odp' => Icons.slideshow_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  /// Whether the bytes are on this device, so [Attachment.isOpenable] is the
  /// question a card is asking. Exposed as a helper so the bubble and the menu
  /// ask it the same way.
  static bool isOpenable(Attachment attachment) => attachment.isOpenable;
}

/// One button on the card.
///
/// Hand-built rather than a `TextButton`: the bubble is already a coloured
/// surface with its own foreground, and Material buttons bring their own
/// colours and their own 48-pixel tap target, which would make a three-button
/// card taller than the message it belongs to.
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

  /// The one button the state is really about — Accept, or Open.
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
