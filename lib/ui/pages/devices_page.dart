import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/discovery/discovery_service.dart';
import '../../core/models/peer.dart';
import '../../l10n/app_localizations.dart';
import '../../state/chat_provider.dart';
import '../../state/lan_provider.dart';
import '../../state/providers.dart';
import '../ui_constants.dart';
import '../widgets/device_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/my_device_card.dart';
import 'chat_page.dart';
import 'settings_page.dart';

/// The device list — design.md §6.2.
///
/// On a wide screen this fills the left pane; on a phone it is the whole app.
/// Tapping a peer opens the conversation, either in the right pane or as a
/// pushed page.
class DevicesPage extends ConsumerWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final List<Peer> peers = ref.watch(peersProvider);
    final Peer? selected = ref.watch(selectedPeerProvider);
    final DiscoveryService discovery = ref.watch(discoveryServiceProvider);

    // Reachable = announcing or connected. The two disagree in both directions
    // — a network that drops UDP ages a peer we hold a connection to out of the
    // announce table, and a peer whose listener could not bind still announces
    // — and either is enough to talk to it, since a message to an absent peer
    // queues rather than fails (§5.2).
    final Set<String> connected =
        ref.watch(onlinePeersProvider).valueOrNull ?? const <String>{};
    bool reachable(Peer peer) => peer.isOnline || connected.contains(peer.id);

    final int onlineCount = peers.where(reachable).length;
    final Map<String, int> unread =
        ref.watch(unreadByPeerProvider).valueOrNull ?? const <String, int>{};

    void openChat(Peer peer) {
      ref.read(selectedPeerProvider.notifier).state = peer;
      if (MediaQuery.sizeOf(context).width < kTwoPaneMinWidth) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ChatPage()),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navDevices),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.rescan,
            onPressed: discovery.rescan,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.navSettings,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: <Widget>[
          _SectionLabel(text: l10n.myDeviceSectionTitle),
          const SizedBox(height: 8),
          const MyDeviceCard(),
          const SizedBox(height: 24),
          _SectionLabel(text: l10n.devicesOnNetworkCount(peers.length)),
          const SizedBox(height: 8),
          if (peers.isEmpty)
            EmptyState(
              onAddByIp: () => _showAddByIpDialog(context),
              onRescan: discovery.rescan,
            )
          else ...<Widget>[
            for (final Peer peer in peers)
              DeviceTile(
                peer: peer,
                online: reachable(peer),
                selected: selected?.id == peer.id,
                unread: unread[peer.id] ?? 0,
                onTap: () => openChat(peer),
                onSendFile: reachable(peer)
                    ? () => _notImplemented(context)
                    : null,
              ),
            const SizedBox(height: 20),
            Center(
              child: TextButton.icon(
                onPressed: () => _showAddByIpDialog(context),
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.addDeviceByIp),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                '$onlineCount/${peers.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Manual peer entry — the escape hatch for networks where multicast and
/// broadcast are both blocked (AP isolation, hardened corporate Wi-Fi).
///
/// The validation is real; the connect step lands with the transport in M2.
Future<void> _showAddByIpDialog(BuildContext context) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final TextEditingController controller = TextEditingController();
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();

  final String? result = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) {
      return AlertDialog(
        title: Text(l10n.addDeviceDialogTitle),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: l10n.addDeviceFieldLabel,
              hintText: l10n.addDeviceFieldHint,
            ),
            validator: (String? value) {
              final String input = (value ?? '').trim();
              if (input.isEmpty) {
                return l10n.addDeviceInvalidIp;
              }
              // InternetAddress throws on anything that is not a literal IP.
              try {
                InternetAddress(input);
              } on ArgumentError {
                return l10n.addDeviceInvalidIp;
              }
              return null;
            },
            onFieldSubmitted: (_) {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(dialogContext).pop(controller.text.trim());
              }
            },
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(dialogContext).pop(controller.text.trim());
              }
            },
            child: Text(l10n.actionAdd),
          ),
        ],
      );
    },
  );

  controller.dispose();

  if (result != null && context.mounted) {
    _notImplemented(context);
  }
}

void _notImplemented(BuildContext context) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('${l10n.notImplementedTitle} — ${l10n.notImplementedBody}'),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
