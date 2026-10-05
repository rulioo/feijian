import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/models/message.dart';
import '../../core/models/peer.dart';
import '../../l10n/app_localizations.dart';
import '../../state/chat_provider.dart';
import '../../state/lan_provider.dart';
import '../../state/lan_service.dart';
import '../../state/providers.dart';
import '../theme/device_icons.dart';
import '../widgets/message_bubble.dart';

/// The conversation view — design.md §6.3.
///
/// The history is a reversed list, so the newest message sits at the bottom and
/// the view opens there without any scroll juggling. A page of older messages
/// appends to the far end, which in a reversed list is the visual top — the one
/// place growth does not move what the user is looking at.
///
/// File bubbles, the drop overlay and the clipboard shortcuts are M3; the
/// composer already has their buttons, and they say what they are waiting for.
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// Which conversation the field currently holds text for.
  ///
  /// The page is reused when the user picks another device in the two-pane
  /// layout — the widget is `const` and keeps its position, so nothing else
  /// tells this state that the peer changed.
  String? _peerId;

  bool _draftSeeded = false;

  /// How close to the top of the history counts as asking for more.
  static const double _loadOlderThreshold = 240;

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Follows the selected peer, resetting the per-conversation state when it
  /// changes. Called from `build`, and deliberately not `setState`: everything
  /// it touches is local to this widget and read by the same build.
  void _followSelection(String peerId, ChatState? state) {
    if (_peerId != peerId) {
      _peerId = peerId;
      _draftSeeded = false;
      _composer.clear();
      // Reversed list: offset 0 is the bottom, which is where opening a
      // conversation should start. The controller keeps its offset across a
      // change of children, so without this the new conversation would open
      // wherever the old one was scrolled to.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(0);
        }
      });
      return;
    }

    // The draft comes from the database, so it arrives one frame after the
    // page does. Seeded exactly once: after that the field belongs to the user,
    // and re-seeding it would fight them for the caret.
    if (!_draftSeeded && state != null) {
      _draftSeeded = true;
      final String draft = state.draft ?? '';
      _composer.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
    }
  }

  Future<void> _send() async {
    final String text = _composer.text;
    final String? peerId = _peerId;
    if (peerId == null || text.trim().isEmpty) {
      return;
    }

    final ChatController controller = ref.read(chatProvider(peerId).notifier);
    // Cleared before the await, not after: the message is already in the
    // controller's hands, and a composer that keeps its text until the database
    // write finishes invites a second tap becoming a second message.
    _composer.clear();
    try {
      await controller.send(text);
    } on Object catch (error) {
      // Nothing was stored, so the text goes back where the user can see it
      // rather than disappearing with an error they cannot act on.
      if (!mounted) {
        return;
      }
      _composer.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      final AppLocalizations l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.sendUnavailable),
          behavior: SnackBarBehavior.floating,
        ),
      );
      debugPrint('[chat] send failed: $error');
    }
  }

  /// Asks for the next page of history, from outside the build phase.
  ///
  /// `loadOlder` moves the provider's state, and moving it while the list is
  /// being built is a rebuild during a build. It is guarded internally against
  /// running twice, so the several places that ask for it are harmless.
  void _requestOlder() {
    final String? peerId = _peerId;
    if (peerId == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(ref.read(chatProvider(peerId).notifier).loadOlder());
    });
  }

  /// The selected peer as it is *now*.
  ///
  /// The selection is a snapshot taken when the user tapped a device, so its
  /// `isOnline` says what was true at that moment and would say it forever. The
  /// announce table is the live answer for everything the page shows.
  Peer _current(Peer selected) {
    for (final Peer peer in ref.watch(peersProvider)) {
      if (peer.id == selected.id) {
        return peer;
      }
    }
    // Gone from the table entirely — dropped after a minute of silence, which
    // is the definition of offline (§4.1).
    return selected.copyWith(isOnline: false);
  }

  /// Asks before emptying a conversation.
  ///
  /// Confirmed, unlike deleting a single message from its menu. That one the
  /// user has just long-pressed, and the menu item sits next to the message it
  /// will remove; this one can destroy years of history from a tap on an icon
  /// with nothing on screen pointing at what will go.
  Future<void> _confirmClearHistory(Peer peer) async {
    final AppLocalizations l10n = AppLocalizations.of(context);

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(l10n.clearHistory),
        content: Text(l10n.clearHistoryConfirm(peer.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              l10n.actionDelete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }
    await ref.read(chatProvider(peer.id).notifier).clearHistory();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.historyCleared),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// Takes a hand-added device off the list.
  ///
  /// Confirmed, and the confirmation says what will *not* happen as well as what
  /// will: the device disappears from the list, the conversation stays. The
  /// alternative — a peer that can only be deleted by reinstalling — is what
  /// this exists to avoid, but a user who has just watched a conversation
  /// vanish would be right to be annoyed.
  ///
  /// The page is left open on purpose. Clearing the selection would look like
  /// the removal had taken the conversation with it, which is the one thing the
  /// dialog promises it has not.
  Future<void> _confirmRemoveDevice(Peer peer) async {
    final AppLocalizations l10n = AppLocalizations.of(context);

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(l10n.removeDevice),
        content: Text(l10n.removeDeviceConfirm(peer.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              l10n.removeDevice,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }
    final LanService? lan = ref.read(lanServiceProvider).valueOrNull;
    if (lan == null) {
      // Only reachable when the network service failed to start, in which case
      // this peer cannot have been added through it either. Forgetting is a
      // list operation first and a connection operation second, and the list is
      // owned by a different provider that is still very much alive.
      ref.read(discoveryServiceProvider).forget(peer.id);
    } else {
      await lan.forgetPeer(peer.id);
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.deviceRemoved(peer.name)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// Everything the app knows about the other device — §6.2's "same name, two
  /// devices" problem, and the first thing worth having when discovery or a
  /// connection misbehaves.
  ///
  /// The id is shown in full rather than abbreviated: it is the one field that
  /// distinguishes two devices sharing a name, and it is what the log prints.
  Future<void> _showPeerInfo(Peer peer) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool reachable =
        peer.isOnline || ref.read(peerOnlineProvider(peer.id));

    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(peer.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _InfoRow(
              label: l10n.peerInfoId,
              value: peer.id,
              selectable: true,
            ),
            _InfoRow(
              label: l10n.peerInfoAddress,
              value: peer.lastIp == null
                  ? '—'
                  : '${peer.lastIp}:${peer.lastPort ?? kDiscoveryPort}',
            ),
            _InfoRow(label: l10n.peerInfoType, value: _typeLabel(l10n, peer)),
            _InfoRow(label: l10n.peerInfoSystem, value: peer.os ?? '—'),
            _InfoRow(
              label: l10n.peerInfoStatus,
              value: reachable ? l10n.statusOnline : l10n.statusOffline,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
  }

  static String _typeLabel(AppLocalizations l10n, Peer peer) {
    return switch (peer.deviceType) {
      DeviceType.windows => l10n.deviceTypeWindows,
      DeviceType.android => l10n.deviceTypeAndroid,
      DeviceType.ios => l10n.deviceTypeIos,
      DeviceType.unknown => l10n.deviceTypeUnknown,
    };
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Peer? selected = ref.watch(selectedPeerProvider);

    if (selected == null) {
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

    final Peer peer = _current(selected);
    final AsyncValue<ChatState> history = ref.watch(chatProvider(peer.id));
    _followSelection(peer.id, history.valueOrNull);

    // Announcing or connected — both mean "a device you can talk to" (§6.2).
    // They disagree in both directions: a network that drops UDP ages a peer we
    // hold a connection to out of the announce table, and a peer whose listener
    // failed still announces. Neither is a reason to tell the user it is gone.
    final bool reachable =
        peer.isOnline || ref.watch(peerOnlineProvider(peer.id));

    // Offered only for a peer the user entered by hand. Those are the ones the
    // ageing rules cannot remove, so without this there would be no way to get
    // rid of a mistyped address short of restarting the app. An announced peer
    // leaves on its own when it stops announcing, and a menu item that looks
    // like it deletes a device but only hides it until the next announce would
    // be a worse lie than no item at all.
    final bool isManual = ref.watch(manualPeerIdsProvider).contains(peer.id);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _ChatHeader(peer: peer, online: reachable),
        actions: <Widget>[
          PopupMenuButton<String>(
            tooltip: l10n.moreActions,
            onSelected: (String value) => switch (value) {
              'info' => unawaited(_showPeerInfo(peer)),
              'clear' => unawaited(_confirmClearHistory(peer)),
              'remove' => unawaited(_confirmRemoveDevice(peer)),
              _ => _showNotImplemented(context),
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'info',
                child: Text(l10n.viewPeerInfo),
              ),
              PopupMenuItem<String>(
                value: 'clear',
                child: Text(l10n.clearHistory),
              ),
              if (isManual) ...<PopupMenuEntry<String>>[
                // Set apart because it is the only item here that acts on the
                // device rather than on the conversation, and the one item of
                // the three that cannot be undone by sending another message.
                const PopupMenuDivider(),
                PopupMenuItem<String>(
                  value: 'remove',
                  child: Text(
                    l10n.removeDevice,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (!reachable) _OfflineBanner(name: peer.name),
          Expanded(child: _history(peer, history)),
          _Composer(
            controller: _composer,
            onChanged: (String value) =>
                ref.read(chatProvider(peer.id).notifier).setDraft(value),
            onSend: () => unawaited(_send()),
          ),
        ],
      ),
    );
  }

  Widget _history(Peer peer, AsyncValue<ChatState> history) {
    return switch (history) {
      AsyncData<ChatState>(:final ChatState value) => _messageList(peer, value),
      AsyncError<ChatState>(:final Object error) => _HistoryFailure(
        onRetry: () => ref.invalidate(chatProvider(peer.id)),
        error: error,
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }

  Widget _messageList(Peer peer, ChatState state) {
    if (state.messages.isEmpty) {
      return _EmptyHistory(name: peer.name);
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        final ScrollMetrics m = notification.metrics;
        if (m.pixels >= m.maxScrollExtent - _loadOlderThreshold) {
          // In a reversed list the far edge is the top of the conversation.
          _requestOlder();
        }
        return false;
      },
      child: ListView.builder(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: 10),
        itemCount: state.messages.length + (state.hasMore ? 1 : 0),
        itemBuilder: (BuildContext context, int index) {
          if (index == state.messages.length) {
            // Building this row means the user has reached the oldest page —
            // or that the whole conversation fits on screen, in which case
            // nothing would ever scroll and nothing else would ask.
            _requestOlder();
            return const _LoadingOlder();
          }
          // Reversed: index 0 is the newest, at the bottom.
          final Message message =
              state.messages[state.messages.length - 1 - index];
          return MessageBubble(
            key: ValueKey<String>(message.id),
            message: message,
            onRetry: () => unawaited(
              ref.read(chatProvider(peer.id).notifier).retry(message.id),
            ),
            onDelete: () => unawaited(
              ref.read(chatProvider(peer.id).notifier).deleteMessage(message.id),
            ),
          );
        },
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.peer, required this.online});

  final Peer peer;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);

    return Row(
      children: <Widget>[
        Icon(peer.icon.filledGlyph, size: 22, color: theme.colorScheme.primary),
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
                online ? l10n.statusOnline : l10n.statusOffline,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: online
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

/// One label/value pair in the device-info dialog.
///
/// The value is selectable only for the fields a user might need to copy out —
/// the device id above all, since it is what has to be quoted to tell two
/// identically named devices apart.
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.selectable = false,
  });

  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? valueStyle = theme.textTheme.bodyMedium;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          if (selectable)
            SelectableText(value, style: valueStyle)
          else
            Text(value, style: valueStyle),
        ],
      ),
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
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          l10n.chatEmptyWithPeer(name),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _LoadingOlder extends StatelessWidget {
  const _LoadingOlder();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Semantics(
          label: l10n.loadingOlderMessages,
          child: const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    );
  }
}

/// The history could not be read. Offers the one action that might help, since
/// the alternative is a page that looks empty and a user who thinks it is.
class _HistoryFailure extends StatelessWidget {
  const _HistoryFailure({required this.onRetry, required this.error});

  final VoidCallback onRetry;
  final Object error;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              color: theme.colorScheme.error,
              size: 28,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.historyLoadFailed,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: onRetry, child: Text(l10n.actionRetry)),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.onChanged,
    required this.onSend,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;

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
              // Always enabled, even with the peer away: the message is stored
              // and owed rather than refused, and the banner above says so
              // (§5.2).
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(hintText: l10n.composerHint),
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),
            // Only the button listens to the field: rebuilding the whole page on
            // every keystroke would rebuild the message list with it.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (BuildContext context, TextEditingValue value, _) {
                return IconButton.filled(
                  icon: const Icon(Icons.send),
                  tooltip: l10n.sendMessage,
                  onPressed: value.text.trim().isEmpty ? null : onSend,
                );
              },
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
