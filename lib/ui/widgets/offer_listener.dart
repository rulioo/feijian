import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/peer.dart';
import '../../core/models/transfer.dart';
import '../../l10n/app_localizations.dart';
import '../../state/data_providers.dart';
import '../../state/providers.dart';
import '../../state/settings_provider.dart';
import '../../state/transfer_provider.dart';
import '../../state/transfer_service.dart';
import '../format.dart';

/// Answers the file offers that arrive at this device — design.md §6.4, §9.2.
///
/// Two behaviours, and the setting picks between them. The default is
/// `confirmBeforeReceiving == false`, and then nothing is asked: an offer is
/// accepted the moment it arrives. Turning the switch on restores the question
/// this widget was built around, and nothing is received until it is answered —
/// nothing is answered on the user's behalf.
///
/// The setting is read when the offer arrives rather than watched, so a switch
/// flipped while an offer is on screen governs the *next* one. The one already
/// on screen has been seen by the user, and replacing its dialog with a silent
/// accept because of something they did in Settings would be the surprise the
/// switch exists to prevent.
///
/// Mounted around the whole shell rather than around the chat page, because an
/// offer is a thing that arrives while the user is doing something else. The
/// chat page is only on screen when a conversation is open, and a file sent to
/// a device sitting on the device list is no less a file the user has to decide
/// about.
///
/// The offer also appears as a bubble in the conversation, with Accept and
/// Decline on its card, and that is where a user who dismissed this dialog
/// answers it. Dismissing decides nothing: the send is not refused by a back
/// gesture, it is left where the sender put it, waiting.
class OfferListener extends ConsumerStatefulWidget {
  const OfferListener({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<OfferListener> createState() => _OfferListenerState();
}

class _OfferListenerState extends ConsumerState<OfferListener> {
  StreamSubscription<Transfer>? _offers;

  /// The service the subscription belongs to, so a rebuilt engine is noticed.
  TransferService? _watched;

  @override
  void dispose() {
    unawaited(_offers?.cancel());
    super.dispose();
  }

  /// Follows the engine, resubscribing when it is replaced.
  ///
  /// Watched rather than read, for the same reason the chat controller watches
  /// it: a new listen port or a new manager builds a new service, and a
  /// subscription left on the old one would go on listening to a stream that
  /// nothing will ever write to again.
  void _follow(TransferService? service) {
    if (identical(service, _watched)) {
      return;
    }
    _watched = service;
    unawaited(_offers?.cancel());
    _offers = service?.offers.listen((Transfer offer) {
      unawaited(_ask(offer));
    });
  }

  /// Acts on one offer: receives it, or puts it on screen to be answered.
  ///
  /// Offers are not queued. The engine already bounds them — it refuses a
  /// fourth concurrent transfer and tells the sender to try later — so several
  /// at once means a handful of files dropped on the window, and a short stack
  /// the user answers in turn is what that deserves.
  Future<void> _ask(Transfer offer) async {
    final TransferService? service = _watched;
    if (service == null) {
      return;
    }

    if (!ref.read(settingsProvider).confirmBeforeReceiving) {
      // The default: receive it and say nothing. No toast either — "Accept" is
      // the word for a button the user pressed, and the conversation bubble
      // and its progress card are the receipt they actually get.
      await service.accept(offer.id);
      return;
    }

    // The name and the size are on the attachment, which is written before the
    // offer is announced — the bubble and this dialog read the same row, so
    // they cannot disagree about what is being offered.
    final Attachment? file =
        await ref.read(transferRepositoryProvider).attachmentFor(offer.id);
    if (!mounted || file == null) {
      // No row to describe it with, and so nothing to ask about: the same
      // lookup failed for the bubble.
      return;
    }

    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool? accepted = await showFileOfferDialog(
      context: context,
      peerName: _nameOf(offer.peerId),
      fileName: file.fileName,
      size: file.size,
    );

    if (!mounted) {
      return;
    }
    // Read again rather than reused: a dialog is open for as long as the user
    // takes, and a rebuilt engine in that time would leave `service` pointing
    // at a disposed one.
    final TransferService? live = _watched;
    if (live == null) {
      return;
    }

    // Null is the dialog being dismissed, and it decides nothing. The offer is
    // still on the wire waiting for an answer, and its bubble is still in the
    // conversation offering the same two buttons.
    if (accepted == null) {
      return;
    }
    if (accepted) {
      await live.accept(offer.id);
      _tell(l10n.fileActionResultAccept);
    } else {
      await live.decline(offer.id);
      _tell(l10n.fileActionResultDecline);
    }
  }

  /// The peer's name, or its id when the list does not have it.
  ///
  /// An offer can outlive the announce that introduced the device — the table
  /// ages a silent peer out after a minute (§4.1), and a transfer already under
  /// way does not stop because of it. The id is ugly and it is identifying,
  /// which is the right way round for a device that is not answering.
  String _nameOf(String peerId) {
    for (final Peer peer in ref.read(peersProvider)) {
      if (peer.id == peerId) {
        return peer.name;
      }
    }
    return peerId;
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

  @override
  Widget build(BuildContext context) {
    _follow(ref.watch(transferServiceProvider).valueOrNull);
    return widget.child;
  }
}

/// The question that is asked when the user has asked to be asked, on its
/// own so it can be put on screen from where the offer arrives (§6.4).
///
/// Returns true for Accept, false for Decline, and null for a dialog the user
/// dismissed without deciding — which is not an answer and must not be read as
/// one.
Future<bool?> showFileOfferDialog({
  required BuildContext context,
  required String peerName,
  required String fileName,
  required int size,
}) {
  final AppLocalizations l10n = AppLocalizations.of(context);

  return showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(l10n.fileOfferTitle),
      content: Text(
        l10n.fileOfferBody(peerName, fileName, formatBytes(l10n, size)),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.fileDecline),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.fileAccept),
        ),
      ],
    ),
  );
}
