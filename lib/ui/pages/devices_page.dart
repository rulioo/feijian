import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/discovery/discovery_service.dart';
import '../../core/models/peer.dart';
import '../../core/transport/connection_manager.dart';
import '../../l10n/app_localizations.dart';
import '../../state/chat_provider.dart';
import '../../state/lan_provider.dart';
import '../../state/lan_service.dart';
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
              onAddByIp: () => unawaited(_showAddByIpDialog(context, ref)),
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
                onPressed: () => unawaited(_showAddByIpDialog(context, ref)),
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
/// Validation is local; the dial is not. An address that passes here is
/// well-formed, which is a different question from whether anything is listening
/// on it, and only the network can answer the second one.
Future<void> _showAddByIpDialog(BuildContext context, WidgetRef ref) async {
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

  if (result == null || !context.mounted) {
    return;
  }
  final InternetAddress? address = InternetAddress.tryParse(result);
  if (address == null) {
    // Unreachable through the dialog, whose validator already rejected this.
    // Said out loud rather than dialled as nothing: two checks disagreeing is a
    // bug, and a silent no-op is the hardest kind to notice.
    _snack(context, l10n.addDeviceInvalidIp);
    return;
  }
  await _addPeer(context, ref, address);
}

/// Dials a typed-in address and reports what came of it.
///
/// A modal rather than a snackbar. A refused port answers in milliseconds, but a
/// *filtered* one — the case this feature exists for — takes the full handshake
/// timeout, and without a spinner that is indistinguishable from the button
/// having done nothing at all. `PopScope` keeps it from being dismissed while
/// the dial is still in flight, which would leave the result with nowhere to go.
Future<void> _addPeer(
  BuildContext context,
  WidgetRef ref,
  InternetAddress address,
) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final String target = '${address.address}:$kDiscoveryPort';
  final NavigatorState navigator = Navigator.of(context, rootNavigator: true);

  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext _) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: <Widget>[
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 20),
            Expanded(child: Text(l10n.addDeviceConnecting(target))),
          ],
        ),
      ),
    ),
  ));

  String message;
  try {
    // Awaited rather than read: on a cold start the service is still binding its
    // sockets, and "not running" would be a wrong answer to a question that just
    // needed asking a moment later.
    final LanService lan = await ref.read(lanServiceProvider.future);
    final DialResult result = await lan.addPeerByAddress(address);
    message = result.isConnected
        ? l10n.addDeviceAdded(result.hello!.name)
        : _addFailureMessage(l10n, result.problem!, target);
  } on Object catch (error) {
    debugPrint('[add-device] $error');
    message = l10n.addDeviceOffline;
  }

  if (navigator.mounted) {
    navigator.pop();
  }
  if (context.mounted) {
    _snack(context, message);
  }
}

/// One sentence per failure, because they call for two different next moves: an
/// address that led nowhere needs checking against the other device, while this
/// device's own address needs the user to read the list again.
String _addFailureMessage(
  AppLocalizations l10n,
  DialProblem problem,
  String target,
) {
  return switch (problem) {
    DialProblem.unreachable => l10n.addDeviceUnreachable(target),
    DialProblem.thisDevice => l10n.addDeviceSelf,
  };
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
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
