import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/peer.dart';
import '../../l10n/app_localizations.dart';
import '../../state/providers.dart';
import '../theme/device_icons.dart';

/// "This device" card at the top of the list — design.md §6.2.
///
/// Making the local device visible is deliberate: it is how a user confirms
/// which name and address their peers will see, which is the first thing to
/// check when something cannot be found on the network.
class MyDeviceCard extends ConsumerWidget {
  const MyDeviceCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AsyncValue<Peer> self = ref.watch(selfDeviceProvider);
    final ThemeData theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: self.when(
          loading: () => const SizedBox(
            height: 48,
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          error: (Object error, StackTrace _) => Text(
            '$error',
            style: theme.textTheme.bodySmall,
          ),
          data: (Peer peer) => Row(
            children: <Widget>[
              _Avatar(peer: peer, online: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            peer.name,
                            style: theme.textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '(${l10n.youLabel})',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      <String?>[
                        peer.lastIp,
                        peer.os,
                      ].whereType<String>().join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Circular device-icon avatar, shared with the peer tiles.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.peer, required this.online});

  final Peer peer;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: online
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: Icon(
        peer.icon.filledGlyph,
        size: 22,
        color: online ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
      ),
    );
  }
}

/// Exposed so [DeviceTile] renders an identical avatar without duplicating the
/// sizing rules.
class PeerAvatar extends StatelessWidget {
  const PeerAvatar({
    required this.peer,
    required this.online,
    super.key,
  });

  final Peer peer;
  final bool online;

  @override
  Widget build(BuildContext context) => _Avatar(peer: peer, online: online);
}
