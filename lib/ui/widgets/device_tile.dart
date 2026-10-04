import 'package:flutter/material.dart';

import '../../core/models/peer.dart';
import '../../l10n/app_localizations.dart';
import 'my_device_card.dart';

/// One row in the device list — design.md §6.2.
///
/// Offline peers stay in the list (greyed, not tappable for sending) because
/// their history is still readable and messages can still be queued for them
/// (design.md §5.2).
class DeviceTile extends StatelessWidget {
  const DeviceTile({
    required this.peer,
    required this.selected,
    required this.onTap,
    this.onSendFile,
    super.key,
  });

  final Peer peer;
  final bool selected;
  final VoidCallback onTap;

  /// Null while the peer is offline — there is nowhere to send to yet.
  final VoidCallback? onSendFile;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);

    return Opacity(
      opacity: peer.isOnline ? 1 : 0.55,
      child: ListTile(
        selected: selected,
        selectedTileColor: theme.colorScheme.primaryContainer.withValues(
          alpha: 0.45,
        ),
        onTap: onTap,
        leading: PeerAvatar(peer: peer, online: peer.isOnline),
        title: Text(
          peer.name,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Row(
          children: <Widget>[
            _StatusDot(online: peer.isOnline),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                <String?>[
                  peer.lastIp,
                  peer.isOnline ? l10n.statusOnline : l10n.statusOffline,
                ].whereType<String>().join(' · '),
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.attach_file, size: 20),
          tooltip: l10n.sendFileAction,
          onPressed: onSendFile,
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
