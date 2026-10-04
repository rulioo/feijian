import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/peer.dart';
import '../../l10n/app_localizations.dart';
import '../../state/providers.dart';
import '../theme/device_icons.dart';

/// The conversation view — design.md §6.3.
///
/// M0 renders the frame: header, offline banner, empty history and composer.
/// The message list itself arrives in M2 and file bubbles in M3.
class ChatPage extends ConsumerWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Peer? peer = ref.watch(selectedPeerProvider);

    if (peer == null) {
      // Only reachable in the two-pane layout, before anything is selected.
      return Scaffold(
        appBar: AppBar(title: Text(l10n.appName)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              l10n.chatEmptyNoPeer,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _ChatHeader(peer: peer),
        actions: <Widget>[
          PopupMenuButton<String>(
            tooltip: l10n.moreActions,
            onSelected: (String value) => _showNotImplemented(context),
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'info',
                child: Text(l10n.viewPeerInfo),
              ),
              PopupMenuItem<String>(
                value: 'clear',
                child: Text(l10n.clearHistory),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (!peer.isOnline) _OfflineBanner(name: peer.name),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  l10n.chatEmptyWithPeer(peer.name),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          _Composer(enabled: peer.isOnline),
        ],
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.peer});

  final Peer peer;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);

    return Row(
      children: <Widget>[
        Icon(
          peer.icon.filledGlyph,
          size: 22,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                peer.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              Text(
                peer.isOnline ? l10n.statusOnline : l10n.statusOffline,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: peer.isOnline
                      ? const Color(0xFF22C55E)
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Explains why the composer still works for an absent peer — messages queue
/// rather than fail (design.md §5.2).
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.schedule_outlined,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.peerOfflineNotice(name),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            IconButton(
              icon: const Icon(Icons.attach_file),
              tooltip: l10n.attachFile,
              onPressed: () => _showNotImplemented(context),
            ),
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: l10n.attachFolder,
              onPressed: () => _showNotImplemented(context),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: TextField(
                enabled: enabled,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(hintText: l10n.composerHint),
                onSubmitted: (_) => _showNotImplemented(context),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              icon: const Icon(Icons.send),
              tooltip: l10n.sendMessage,
              onPressed: enabled ? () => _showNotImplemented(context) : null,
            ),
          ],
        ),
      ),
    );
  }
}

void _showNotImplemented(BuildContext context) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('${l10n.notImplementedTitle} — ${l10n.notImplementedBody}'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ),
  );
}
