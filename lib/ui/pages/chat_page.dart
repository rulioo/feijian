import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/constants.dart';
import '../../core/models/message.dart';
import '../../core/models/peer.dart';
import '../../core/models/transfer.dart';
import '../../core/protocol/payloads.dart';
import '../../core/transfer/safe_name.dart';
import '../../l10n/app_localizations.dart';
import '../../platform/file_chooser.dart';
import '../../state/chat_provider.dart';
import '../../state/lan_provider.dart';
import '../../state/lan_service.dart';
import '../../state/providers.dart';
import '../../state/transfer_provider.dart';
import '../../state/transfer_service.dart';
import '../theme/device_icons.dart';
import '../widgets/drop_region.dart';
import '../widgets/message_bubble.dart';
import 'image_viewer_page.dart';

/// The conversation view — design.md §6.3.
///
/// The history is a reversed list, so the newest message sits at the bottom and
/// the view opens there without any scroll juggling. A page of older messages
/// appends to the far end, which in a reversed list is the visual top — the one
/// place growth does not move what the user is looking at.
///
/// A file message draws as a card, a finished picture as a thumbnail that opens
/// the fullscreen viewer (§6.3), and a transfer still moving as a bar over the
/// same card. A folder is a card of its own: a name, a count and the task's own
/// progress, because §4.6 makes it a message over many files rather than one of
/// them (see [FolderCard]).
///
/// Files go out from the paperclip or by being dropped on the conversation, both
/// of which end in [_offerFiles]; a folder from the folder button or a dropped
/// one, which end in [_sendFolder]. The clipboard shortcuts are still to come,
/// and the one that is not wired says so rather than doing nothing.
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

  /// Asks the operating system for files and offers them here — §6.3.
  ///
  /// The `mounted` check is not about this widget being gone when the dialog
  /// closes, though it can be. It is about [context]: the dialog is modal over
  /// the whole app, and a device picked in the other pane while it was open
  /// rebuilds this page — the paths that come back belong to whatever is on
  /// screen when they arrive, and [_offerFiles] reads the peer from there.
  Future<void> _attachFiles() async {
    final List<String> paths = await ref.read(fileChooserProvider).pickFiles();
    if (!mounted) {
      return;
    }
    await _offerFiles(paths);
  }

  /// Asks the operating system for a folder and offers it here — §6.3.
  ///
  /// Nothing is validated here: whether the folder can be read is the walk's
  /// answer, in [TransferService.sendFolder], and answering it twice would be
  /// two places that disagree the moment one changes.
  Future<void> _attachFolder() async {
    final String? path = await ref.read(fileChooserProvider).pickFolder();
    if (!mounted || path == null) {
      return;
    }
    await _sendFolder(path);
  }

  /// Offers one folder to the open conversation — §4.6's folder rules.
  ///
  /// The peer is read here rather than passed in, for the same reason
  /// [_offerFiles] reads it: the dialog is modal over the whole app, and a
  /// device picked in the other pane while it was open would make the folder
  /// belong to a conversation it was not dropped on.
  ///
  /// A failure is told, not thrown onward: the user asked for a folder, and the
  /// walk may take a second on a big one, so a refusal has to arrive as an answer
  /// rather than as a page that did nothing.
  Future<void> _sendFolder(String path) async {
    final String? peerId = _peerId;
    if (peerId == null) {
      return;
    }
    final TransferService? transfers =
        ref.read(transferServiceProvider).valueOrNull;
    if (transfers == null) {
      _tell(AppLocalizations.of(context).sendUnavailable);
      return;
    }

    try {
      await transfers.sendFolder(peerId: peerId, directory: Directory(path));
    } on TransferException catch (error) {
      if (!mounted) {
        return;
      }
      _tell(_refusal(error, SafeName.fileName(path)));
      debugPrint('[chat] folder offer failed for $path: $error');
    }
  }

  /// What to say about a refusal, in the terms the user can act on.
  ///
  /// Shared by the file and folder paths because the two refusals differ only in
  /// which of the engine's reasons they carry: `busy` is the app's own ceiling on
  /// concurrent transfers and naming the file would suggest the file is the
  /// problem; `unsupported` is §4.6 rule 5's manifest too large to send, which is
  /// about the folder's shape rather than about this device; `notFound` is a file
  /// or folder the walk could not read. Everything else is the generic sentence,
  /// with the name in it so the user knows which of a dropped five it was.
  String _refusal(TransferException error, String name) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return switch (error.reason) {
      RejectReason.busy => l10n.fileTooManyTransfers,
      RejectReason.unsupported => l10n.folderTooManyFiles,
      RejectReason.notFound => l10n.folderUnreadable,
      _ => l10n.fileSendFailed(name),
    };
  }

  /// Offers each of [paths] to the open conversation, one transfer apiece.
  ///
  /// One offer per file rather than one transfer carrying many: §4.6's handshake
  /// describes a single file — a name, a size, one answer — and saying "three of
  /// these five are done" would need a batch's worth of states that nothing else
  /// in the protocol has.
  ///
  /// The peer is read once, before the first offer. A user who switches
  /// conversation halfway through a five-file drop is looking at a different
  /// page, but the files were dropped on *this* one, and that is where they were
  /// addressed.
  ///
  /// A file the engine refuses does not stop the ones after it: dropping a
  /// folder and four files on the window should send the four.
  Future<void> _offerFiles(List<String> paths) async {
    final String? peerId = _peerId;
    if (peerId == null || paths.isEmpty) {
      return;
    }

    final TransferService? transfers =
        ref.read(transferServiceProvider).valueOrNull;
    if (transfers == null) {
      // The same sentence an unsent message gets. From here they are the same
      // thing: nothing is listening on the network, so nothing can be offered.
      _tell(AppLocalizations.of(context).sendUnavailable);
      return;
    }

    for (final String path in paths) {
      if (!mounted) {
        return;
      }
      // A dropped folder is the same thing the folder button asks for, and a
      // drop is the likeliest way to arrive with one.
      if (FileSystemEntity.isDirectorySync(path)) {
        await _sendFolder(path);
        continue;
      }

      try {
        await transfers.sendFile(peerId: peerId, file: File(path));
      } on TransferException catch (error) {
        if (!mounted) {
          return;
        }
        _tell(_refusal(error, SafeName.fileName(path)));
        debugPrint('[chat] offer failed for $path: $error');
      }
    }
  }

  /// Copies a finished file to wherever the user points — §6.3.
  ///
  /// Silence for a dialog the user closed: they know they closed it, and a toast
  /// would be the app answering a question nobody asked. Absent entirely on
  /// Android — see [FileChooser.canSaveAs], which is what decides whether the
  /// button is offered at all.
  Future<void> _saveAs(Attachment attachment) async {
    final String? path = attachment.localPath;
    if (path == null || !File(path).existsSync()) {
      _tell(AppLocalizations.of(context).fileMissing);
      return;
    }

    final FileChooser chooser = ref.read(fileChooserProvider);
    final String? target = await chooser.pickSaveLocation(attachment.fileName);
    if (target == null || !mounted) {
      return;
    }

    final bool copied = await chooser.copy(path, target);
    if (!mounted) {
      return;
    }
    final AppLocalizations l10n = AppLocalizations.of(context);
    _tell(copied ? l10n.fileSaved : l10n.fileSaveFailed);
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

  /// Hands a finished file to whatever this system opens it with — §6.3.
  ///
  /// The existence check is not redundant with the engine's error code. On
  /// Windows the hand-off is a `cmd /c start`, which reports success as soon as
  /// the shell accepts the name — so a file deleted from the Downloads folder
  /// by hand would open nothing and say nothing, and the user would be left
  /// pressing a button that does not appear to work.
  Future<void> _openFile(Attachment attachment) async {
    final String? path = attachment.localPath;
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (path == null || !File(path).existsSync()) {
      _tell(l10n.fileMissing);
      return;
    }

    final OpenResult result = await OpenFilex.open(path);
    if (result.type == ResultType.done || !mounted) {
      return;
    }
    // `fileNotFound` is the file going away between the check and the call, or
    // a platform that could not reach it — the same sentence either way.
    // Everything else is the "nothing here opens this" case, which is the one
    // the user can do something about.
    _tell(
      result.type == ResultType.fileNotFound
          ? l10n.fileMissing
          : l10n.fileOpenFailed,
    );
  }

  /// Stops a transfer the user no longer wants — §4.6's cancellation rule.
  ///
  /// Silent when the engine is not up or the transfer has already ended: the
  /// bubble is about to be rebuilt from the row either way, and a toast saying
  /// "cancelled" over a card that still says "Completed" would be the lie.
  Future<void> _cancelTransfer(Attachment attachment) async {
    final TransferService? transfers =
        ref.read(transferServiceProvider).valueOrNull;
    if (transfers == null) {
      return;
    }
    await transfers.cancelAttachment(attachment.id);
    if (!mounted) {
      return;
    }
    _tell(AppLocalizations.of(context).fileCancelled);
  }

  /// Stops a whole folder — the same rule as [_cancelTransfer], one level up.
  ///
  /// By the task's own id rather than through a lookup: §4.6 gives a folder one
  /// `xferId` for all of it, and the transfer row is where that id lives, so the
  /// card already holds the name the engine answers to. A file's card has to go
  /// through [TransferService.cancelAttachment] because the attachment id it
  /// holds is the local one, which the wire has never heard of.
  ///
  /// What stops is the *task*: the file being written is abandoned with its
  /// `.part`, and the sender is told not to send the ones behind it (§4.6). The
  /// files already landed stay — they are on disk and in the attachment rows.
  Future<void> _cancelTask(Transfer task) async {
    final TransferService? transfers =
        ref.read(transferServiceProvider).valueOrNull;
    if (transfers == null) {
      return;
    }
    await transfers.cancel(task.id);
    if (!mounted) {
      return;
    }
    _tell(AppLocalizations.of(context).fileCancelled);
  }

  /// Agrees to an offer that is waiting in the conversation — §9.2.
  ///
  /// The same decision the dialog over the whole app asks for, reached the
  /// other way round: a user who dismissed the dialog, or who opened the
  /// conversation after it was asked, still has to be able to say yes.
  Future<void> _acceptOffer(Attachment attachment) async {
    final TransferService? transfers =
        ref.read(transferServiceProvider).valueOrNull;
    if (transfers == null) {
      return;
    }
    await transfers.acceptAttachment(attachment.id);
    if (mounted) {
      _tell(AppLocalizations.of(context).fileActionResultAccept);
    }
  }

  /// Turns one down. Refusing is a message to the sender, not a silence — it is
  /// told which of the two happened, so its bubble can say so.
  Future<void> _declineOffer(Attachment attachment) async {
    final TransferService? transfers =
        ref.read(transferServiceProvider).valueOrNull;
    if (transfers == null) {
      return;
    }
    await transfers.declineAttachment(attachment.id);
    if (mounted) {
      _tell(AppLocalizations.of(context).fileActionResultDecline);
    }
  }

  /// Says yes to a whole folder — §9.2, where an offer is answered once.
  ///
  /// The task's id rather than an attachment's, because §4.6 gives a folder one
  /// `xferId` for all of it and the transfer row is where that id lives. There is
  /// no partial accept: the receiver takes the tree or turns it down, and every
  /// file in it is written under one root the service picks (§7.1).
  Future<void> _acceptTask(Transfer task) async {
    final TransferService? transfers =
        ref.read(transferServiceProvider).valueOrNull;
    if (transfers == null) {
      return;
    }
    await transfers.accept(task.id);
    if (mounted) {
      _tell(AppLocalizations.of(context).fileActionResultAccept);
    }
  }

  /// Turns a whole folder down. The sender is told which of the two happened,
  /// as it is for a file, so its bubble can say so rather than time out.
  Future<void> _declineTask(Transfer task) async {
    final TransferService? transfers =
        ref.read(transferServiceProvider).valueOrNull;
    if (transfers == null) {
      return;
    }
    await transfers.decline(task.id);
    if (mounted) {
      _tell(AppLocalizations.of(context).fileActionResultDecline);
    }
  }

  /// Sends a file again after an attempt at it ended — §6.3's retry.
  ///
  /// Deliberately *not* the call a text message's retry makes.
  /// [ChatController.retry] puts the message back in the outbox, and the outbox
  /// is text-only ([MessageDao.pendingFor] says why) — a file requeued there
  /// would sit at `pending` with nothing able to send it, which is what the
  /// exclamation did before this existed. A file's retry is a new offer, so it
  /// goes to the engine.
  ///
  /// **Which endings get one.** Anything that is not a success: failed, and also
  /// cancelled and declined, which the database records as a failed *message*
  /// too (§4.5 has no third word for it) and which therefore draw the same
  /// exclamation. Both are reasonable things to want again — the user stopped a
  /// transfer because the network or the moment was wrong, or the peer said no
  /// and has since changed their mind. Tapping the icon is a new decision, and
  /// the engine answers it with a new attempt.
  ///
  /// A refresh afterwards because the engine writes the *message* row back to
  /// `pending`, and the footer's icon is drawn from that row. Without the re-read
  /// the bubble would show a progress bar climbing under a red exclamation — and
  /// a second tap on it would start a second transfer of the same file, which the
  /// engine's own ceiling would then refuse.
  Future<void> _retryTransfer(Attachment attachment) async {
    final String? peerId = _peerId;
    if (peerId == null) {
      return;
    }

    final TransferService? transfers =
        ref.read(transferServiceProvider).valueOrNull;
    if (transfers == null) {
      // The same sentence an unsent message gets, for the same reason: nothing
      // is listening on the network, so nothing can be offered.
      _tell(AppLocalizations.of(context).sendUnavailable);
      return;
    }

    try {
      await transfers.retryAttachment(
        peerId: peerId,
        attachmentId: attachment.id,
      );
    } on TransferException catch (error) {
      if (!mounted) {
        return;
      }
      final AppLocalizations l10n = AppLocalizations.of(context);
      _tell(switch (error.reason) {
        RejectReason.busy => l10n.fileTooManyTransfers,
        // The file behind the card is gone or is no longer the file that was
        // offered. §5.2 asks for that to be said in its own words rather than
        // as a failure of the transfer.
        RejectReason.notFound => l10n.fileMissing,
        _ => l10n.fileSendFailed(attachment.fileName),
      });
      debugPrint('[chat] retry failed for ${attachment.id}: $error');
      return;
    }

    if (!mounted) {
      return;
    }
    await ref.read(chatProvider(peerId).notifier).refresh();
  }

  /// Opens the conversation's pictures at the one that was tapped.
  ///
  /// Given every picture rather than the one tapped, because §6.3 asks the
  /// viewer to swipe between them; [pictures] is the same list for every bubble
  /// on the page, built once per build rather than once per tap.
  Future<void> _openImage(List<Attachment> pictures, Attachment tapped) async {
    final int index = pictures.indexWhere((Attachment a) => a.id == tapped.id);
    if (index < 0) {
      return;
    }
    await Navigator.of(context).push(
      ImageViewerPage.route(images: pictures, initialIndex: index),
    );
  }

  /// The conversation's pictures, oldest first — the order the chat shows them
  /// in, so a swipe moves the way the list scrolls.
  ///
  /// Only the ones whose bytes are here and that this app can decode: an image
  /// still arriving is a card, and putting it in the viewer would give the user
  /// a blank page to swipe onto. `Attachment.isImage` is the same test the
  /// bubble makes, which is what keeps the two lists the same list.
  static List<Attachment> _picturesIn(ChatState state) {
    final List<Attachment> pictures = <Attachment>[];
    for (final Message message in state.messages) {
      // Every file of every message, which for a folder is all the photographs
      // inside it: they are pictures this app received either way, and a
      // received folder is not a reason to be unable to swipe through them.
      for (final Attachment file in state.attachments[message.id] ??
          const <Attachment>[]) {
        if (file.isImage && file.isOpenable) {
          pictures.add(file);
        }
      }
    }
    return pictures;
  }

  void _tell(String message) {
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
    // The write can fail — a foreign key that refuses the delete, a locked
    // database — and when it does, the conversation is still on screen. Saying
    // 「History cleared」 over it is the one outcome the user cannot act on, so
    // the failure gets its own line rather than the same silence.
    bool cleared = false;
    try {
      await ref.read(chatProvider(peer.id).notifier).clearHistory();
      cleared = true;
    } on Object {
      cleared = false;
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(cleared ? l10n.historyCleared : l10n.historyClearFailed),
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

    // Around the Scaffold rather than inside the body, so the drop covers the
    // composer as well: a file dropped on the message field is a file dropped on
    // the conversation, and the region that stopped at the list would say
    // otherwise for the bottom hundred pixels of the page.
    return DropRegion(
      onFiles: (List<String> paths) => unawaited(_offerFiles(paths)),
      child: Scaffold(
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
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
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
              onAttachFile: () => unawaited(_attachFiles()),
              onAttachFolder: () => unawaited(_attachFolder()),
            ),
          ],
        ),
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

    // Built once for the page, not per bubble: every picture bubble hands the
    // viewer the same run of them, and rebuilding it fifty times per frame to
    // hand back the same list would be work for nothing.
    final List<Attachment> pictures = _picturesIn(state);

    // A property of the platform, so it is asked once rather than per bubble —
    // and asked of the chooser, because the answer is why Save as is missing on
    // Android rather than a second opinion formed here.
    final bool canSaveAs = ref.read(fileChooserProvider).canSaveAs;

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
          final List<Attachment> files =
              state.attachments[message.id] ?? const <Attachment>[];
          // A folder is not one of its files, and is not drawn through one:
          // §4.6 makes it a message and a task over many, so the card gets the
          // whole list and the task instead of a single row.
          final bool folder = message.type == MessageType.folder;
          final Attachment? file = folder ? null : files.firstOrNull;
          final Transfer? task = folder ? state.tasks[message.id] : null;
          // An offer this device has been sent and has not answered. The
          // direction is the message's, not the attachment's: §5.1 gives an
          // attachment no direction of its own, and both ends of a transfer
          // write the same shape of row. A folder's answer is one answer about
          // the whole of it — §9.2 has no partial accept — so it is asked of the
          // task rather than of any file.
          final bool answering = message.direction == MessageDirection.incoming &&
              (folder
                  ? task?.state == TransferState.offered
                  : file?.state == TransferState.offered);
          // §6.3's exclamation, which is one affordance over three kinds of
          // message.
          //
          // **A folder gets none.** §5.2's retry re-reads the source, and a
          // folder's source is not on any row this page holds — §4.6 keeps a
          // folder's files on the sender's disk and puts only the manifest on
          // the wire. So what a user does about a failed folder is send it
          // again, which the folder button is for. Null rather than a callback
          // that does nothing: an icon that answers a tap with silence is worse
          // than an icon that is plainly not pressable.
          //
          // **A file's goes to the engine**, because the message's retry cannot
          // carry it: [ChatController.retry] puts the row back in the outbox,
          // and the outbox is text-only. Keyed on the rows rather than on the
          // card's buttons, because cancelled and declined are failed
          // *messages* too (§4.5 has no third word for them), and the engine is
          // the thing that knows what to do with all three.
          //
          // **Text takes the outbox**, which is the one path that really does
          // resend the same message (§5.2).
          final VoidCallback? onRetry;
          if (folder) {
            onRetry = null;
          } else if (file != null && message.status == MessageStatus.failed) {
            onRetry = () => unawaited(_retryTransfer(file));
          } else {
            onRetry = () => unawaited(
                  ref.read(chatProvider(peer.id).notifier).retry(message.id),
                );
          }
          final bool openable = folder
              ? files.any((Attachment f) => f.isOpenable)
              : file != null && file.isOpenable;
          return MessageBubble(
            key: ValueKey<String>(message.id),
            message: message,
            attachment: file,
            files: files,
            task: task,
            onRetry: onRetry,
            // Not `unawaited`: the bubble's menu waits for the answer so its
            // toast can be the truth rather than a hope.
            onDelete: () =>
                ref.read(chatProvider(peer.id).notifier).deleteMessage(
                      message.id,
                    ),
            // Only once the bytes are here. The card offers whatever it is
            // given, and Open on a file that is half arrived is a button that
            // opens half a file.
            onOpen: file == null || !file.isOpenable
                ? null
                : () => unawaited(_openFile(file)),
            // The same condition as Open, plus the platform's answer: copying a
            // file out needs a system dialog, and a button that did nothing when
            // pressed would be worse than one that is not there.
            onSaveAs: file == null || !file.isOpenable || !canSaveAs
                ? null
                : () => unawaited(_saveAs(file)),
            // A folder's two, per file. The card decides whether to offer them
            // at all; a folder with nothing arrived yet offers neither.
            onOpenFile: openable ? (Attachment f) => unawaited(_openFile(f)) : null,
            onSaveFile: openable && canSaveAs
                ? (Attachment f) => unawaited(_saveAs(f))
                : null,
            // Offered while there is something to stop. A file that is here, or
            // that never will be, has no transfer left to cancel, and the button
            // would be a promise the service cannot keep. An unanswered offer is
            // the third case: it has something to stop, but "Cancel" and
            // "Decline" would be two words for one decision — and for a folder
            // that case is the task's, since answering it is one decision about
            // the whole of it.
            onCancel: answering || (folder ? task?.isFinished ?? true : false)
                ? null
                : folder
                    ? () => unawaited(_cancelTask(task!))
                    : file == null || file.isFinished
                        ? null
                        : () => unawaited(_cancelTransfer(file)),
            // A folder's answer is the task's, for the same reason its cancel
            // is: one `xferId` for the whole of it, and a decision about all of
            // it. [TransferService.acceptAttachment] cannot reach it — a folder
            // transfer has no `attachment_id` to be found by.
            onAccept: !answering
                ? null
                : folder
                    ? () => unawaited(_acceptTask(task!))
                    : () => unawaited(_acceptOffer(file!)),
            onDecline: !answering
                ? null
                : folder
                    ? () => unawaited(_declineTask(task!))
                    : () => unawaited(_declineOffer(file!)),
            onOpenImage: file == null
                ? null
                : () => unawaited(_openImage(pictures, file)),
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
    required this.onAttachFile,
    required this.onAttachFolder,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final VoidCallback onAttachFile;
  final VoidCallback onAttachFolder;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        border:
            Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
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
              onPressed: onAttachFile,
            ),
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: l10n.attachFolder,
              onPressed: onAttachFolder,
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

/// Says a menu item is not built yet — the peer-info sheet's remaining rows, and
/// whatever the next one to be added here leaves unfinished.
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
