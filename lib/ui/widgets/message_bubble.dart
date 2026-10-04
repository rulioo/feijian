import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/models/message.dart';
import '../../l10n/app_localizations.dart';

/// One message in a conversation — design.md §6.3.
///
/// The layout is deliberately plain: the sender's own messages sit on the
/// trailing edge in the primary colour, the peer's on the leading edge in a
/// neutral surface. Both edges are direction-relative (`textDirection` runs the
/// `Row`), so an RTL locale mirrors the whole conversation without a second
/// layout (§8.1).
///
/// Long-press (touch) or right-click (mouse) opens the message menu of §6.3.
/// The text is a plain `Text` and not a `SelectableText` because of it: a
/// `SelectableText` claims the long-press for its own selection toolbar, so the
/// menu would open on the desktop and never on the phone — the platform the app
/// is primarily for. The trade is deliberate. Selecting part of a chat bubble is
/// not a thing people do; copying the message is, and the menu does that.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    required this.message,
    required this.onRetry,
    this.onDelete,
    super.key,
  });

  final Message message;

  /// Called when the user taps a failed message's warning icon.
  final VoidCallback onRetry;

  /// Called from the message menu's delete item.
  ///
  /// Null hides the item, which is how a bubble that has no text to copy — a
  /// file message, from M3 — will offer only what applies to it.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool mine = message.direction == MessageDirection.outgoing;

    final ColorScheme scheme = theme.colorScheme;
    final Color background = mine
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final Color foreground = mine
        ? scheme.onPrimaryContainer
        : scheme.onSurface;

    final String text = message.text ?? '';

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 3, 12, 3),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: <Widget>[
          Flexible(
            child: ConstrainedBox(
              // A bubble that spans the window makes a two-word message look
              // like a paragraph, and one that hugs a long line is unreadable.
              constraints: const BoxConstraints(maxWidth: 520),
              child: GestureDetector(
                // Both triggers for the same menu: a phone has no right button
                // and a desktop user does not long-press. `onLongPressStart`
                // rather than `onLongPress` because the menu is anchored where
                // the press began, and only the `Start` variant carries it.
                onLongPressStart: (LongPressStartDetails details) =>
                    _showMenu(context, at: details.globalPosition),
                onSecondaryTapDown: (TapDownDetails details) =>
                    _showMenu(context, at: details.globalPosition),
                child: Container(
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadiusDirectional.only(
                      topStart: const Radius.circular(16),
                      topEnd: const Radius.circular(16),
                      bottomStart: Radius.circular(mine ? 16 : 4),
                      bottomEnd: Radius.circular(mine ? 4 : 16),
                    ),
                  ),
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: foreground,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 3),
                      _Footer(
                        message: message,
                        mine: mine,
                        color: foreground.withValues(alpha: 0.65),
                        onRetry: onRetry,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Opens the context menu of §6.3 at [at], in global coordinates.
  ///
  /// Anchored to the gesture rather than to the bubble's own rectangle: the
  /// rectangle that `findRenderObject` returns here is the full-width row the
  /// bubble sits in, so the menu would land at the screen edge instead of on the
  /// message. The press point is also what a desktop user expects a context menu
  /// to open from, and on a phone it is where the finger already is.
  Future<void> _showMenu(BuildContext context, {required Offset at}) async {
    final String text = message.text ?? '';
    if (text.isEmpty && onDelete == null) {
      // Nothing this bubble can offer — a file message with no caption, once M3
      // lands. An empty popup would be worse than no response.
      return;
    }

    final AppLocalizations l10n = AppLocalizations.of(context);
    final Size screen = MediaQuery.sizeOf(context);

    final _MessageAction? action = await showMenu<_MessageAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        at.dx,
        at.dy,
        screen.width - at.dx,
        screen.height - at.dy,
      ),
      items: <PopupMenuEntry<_MessageAction>>[
        if (text.isNotEmpty)
          PopupMenuItem<_MessageAction>(
            value: _MessageAction.copy,
            child: _MenuRow(
              icon: Icons.copy_outlined,
              label: l10n.messageActionCopy,
            ),
          ),
        if (onDelete != null)
          PopupMenuItem<_MessageAction>(
            value: _MessageAction.delete,
            child: _MenuRow(
              icon: Icons.delete_outline,
              label: l10n.messageActionDelete,
              destructive: true,
            ),
          ),
      ],
    );

    if (action == null || !context.mounted) {
      return;
    }
    switch (action) {
      case _MessageAction.copy:
        // Written before the confirmation is shown, so the message is on the
        // clipboard by the time the user is told that it is.
        await Clipboard.setData(ClipboardData(text: text));
        if (!context.mounted) {
          return;
        }
        _toast(context, l10n.messageCopied);
      case _MessageAction.delete:
        onDelete?.call();
        _toast(context, l10n.messageDeleted);
    }
  }
}

enum _MessageAction { copy, delete }

/// One line of the message menu.
///
/// Hand-built rather than a `ListTile`: a dense `ListTile` inside a
/// `PopupMenuItem` overflows the item's 48-pixel minimum height.
///
/// The label is `Flexible` because a popup menu caps its items at 256 logical
/// pixels. A `Row` sized to `max` puts the overflow on the screen as the
/// striped bar rather than shrinking the text, which is how a long label in a
/// future locale would ship a visibly broken menu.
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = destructive ? scheme.error : scheme.onSurface;

    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color),
          ),
        ),
      ],
    );
  }
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
}

/// The time and, for the sender's own messages, the delivery state.
///
/// Only the sender sees a state: the receiver's copies are all `received`, and a
/// tick on them would mean nothing to look at.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.message,
    required this.mine,
    required this.color,
    required this.onRetry,
  });

  final Message message;
  final bool mine;
  final Color color;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    // The app's locale, not `Intl`'s default: the two agree today, and would
    // stop agreeing the moment a language is added (§8.1).
    final String time = DateFormat.jm(
      l10n.localeName,
    ).format(message.createdAt.toLocal());

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          time,
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontSize: 11,
          ),
        ),
        if (mine) ...<Widget>[
          const SizedBox(width: 4),
          _StatusIcon(
            status: message.status,
            color: color,
            failedColor: theme.colorScheme.error,
            onRetry: onRetry,
          ),
        ],
      ],
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({
    required this.status,
    required this.color,
    required this.failedColor,
    required this.onRetry,
  });

  final MessageStatus status;
  final Color color;
  final Color failedColor;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);

    return switch (status) {
      MessageStatus.pending => Tooltip(
        message: l10n.messageStatusPending,
        child: Icon(Icons.schedule, size: 13, color: color),
      ),
      MessageStatus.sent => Tooltip(
        message: l10n.messageStatusSent,
        child: Icon(Icons.check, size: 14, color: color),
      ),
      MessageStatus.delivered => Tooltip(
        message: l10n.messageStatusDelivered,
        child: Icon(Icons.done_all, size: 14, color: color),
      ),
      // The only state that asks for something. Tapping it is the whole retry
      // affordance — an icon a user can see and press, rather than a hidden
      // gesture on the bubble (§6.3).
      MessageStatus.failed => InkWell(
        onTap: onRetry,
        customBorder: const CircleBorder(),
        child: Tooltip(
          message: l10n.messageStatusFailed,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(Icons.error_outline, size: 15, color: failedColor),
          ),
        ),
      ),
      MessageStatus.received => const SizedBox.shrink(),
    };
  }
}
