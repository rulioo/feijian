import 'package:flutter/material.dart';

import '../../core/models/peer.dart';
import '../../l10n/app_localizations.dart';
import 'my_device_card.dart';

/// One row in the device list — design.md §6.2.
///
/// Offline peers stay in the list (greyed, with their history still readable)
/// because messages can still be queued for them (design.md §5.2).
///
/// [online] is passed in rather than read from [peer]: reachability has two
/// sources — announcing and connected — and only the page knows both.
class DeviceTile extends StatelessWidget {
  const DeviceTile({
    required this.peer,
    required this.online,
    required this.selected,
    required this.onTap,
    this.unread = 0,
    this.onSendFile,
    super.key,
  });

  final Peer peer;
  final bool online;
  final bool selected;

  /// Messages received from this peer that the user has not opened yet. Shown
  /// as a badge, because §6.2's list is where a message from another device is
  /// noticed at all.
  final int unread;

  final VoidCallback onTap;

  /// Null while the peer is offline — there is nowhere to send to yet.
  final VoidCallback? onSendFile;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);

    return Opacity(
      opacity: online ? 1 : 0.55,
      child: ListTile(
        selected: selected,
        selectedTileColor: theme.colorScheme.primaryContainer.withValues(
          alpha: 0.45,
        ),
        onTap: onTap,
        leading: PeerAvatar(peer: peer, online: online),
        title: Text(
          peer.name,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Row(
          children: <Widget>[
            _StatusDot(online: online),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                <String?>[
                  peer.lastIp,
                  online ? l10n.statusOnline : l10n.statusOffline,
                ].whereType<String>().join(' · '),
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (unread > 0) _UnreadBadge(count: unread),
            IconButton(
              icon: const Icon(Icons.attach_file, size: 20),
              tooltip: l10n.sendFileAction,
              onPressed: onSendFile,
            ),
          ],
        ),
      ),
    );
  }
}

/// How many messages are waiting to be read.
///
/// Capped at "99+" rather than growing: the badge is a nudge, and its exact
/// width is not worth a layout that changes shape at three digits.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final String label = count > 99 ? '99+' : '$count';

    return Semantics(
      label: l10n.unreadMessagesCount(count),
      child: Container(
        constraints: const BoxConstraints(minWidth: 20),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: online ? const Color(0xFF22C55E) : scheme.outline,
        shape: BoxShape.circle,
      ),
    );
  }
}
