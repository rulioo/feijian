import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/transfer.dart';
import '../../platform/notification_sound.dart';
import '../../state/lan_provider.dart';
import '../../state/lan_service.dart';
import '../../state/settings_provider.dart';
import '../../state/transfer_provider.dart';
import '../../state/transfer_service.dart';

/// How long one chime keeps the next one quiet — design.md §6.6.
///
/// A peer's backlog arrives in a burst, not a trickle: §5.2 makes a message owed
/// until it is delivered, so a device that was away for an hour hands over
/// everything it has the moment it reconnects, and thirty messages land in the
/// same second. Thirty chimes is not thirty times the notification — it is a
/// single unpleasant noise followed by a user who turns the feature off.
///
/// Short enough that two messages typed a breath apart still sound like two:
/// this is a de-burster, not a digest. And it is deliberately *not* a summary
/// ("3 new messages") — that would need a UI for something the conversation
/// already shows.
const Duration kChimeCooldown = Duration(seconds: 2);

/// Rings once when a message arrives from a peer — design.md §6.6.
///
/// Two sources, one sink, and the sink is why the two can share it: this widget
/// only ever *consumes* events, so the loop that makes a single bus dangerous
/// elsewhere (a read announcing itself to the thing that asked for it) cannot
/// happen here. The two are the two ways a message can arrive:
///
///  * text, through [`LanService.messagesArrived`] — a packet that carried words;
///  * a file or a folder, through [`TransferService.offers`] — a packet that
///    carried an offer, whose message row the transfer engine writes itself.
///
/// A file is not a lesser kind of message here. §5.1 stores one as a message
/// with a transfer behind it and the conversation reads them the same way, so a
/// chime that only honoured text would be silent for exactly the arrival a user
/// is most likely to be away for.
///
/// Mounted around the whole app rather than around the conversation: a message
/// arrives whether or not its page is open, and being told about it is the point
/// of the sound.
class MessageChime extends ConsumerStatefulWidget {
  const MessageChime({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<MessageChime> createState() => _MessageChimeState();
}

class _MessageChimeState extends ConsumerState<MessageChime> {
  StreamSubscription<String>? _arrived;
  StreamSubscription<Transfer>? _offers;

  /// The services the two subscriptions belong to, so a rebuilt one is noticed.
  LanService? _watchedLan;
  TransferService? _watchedTransfers;

  /// Runs while the last chime is still recent. Null when nothing is ringing.
  Timer? _cooldown;

  @override
  void dispose() {
    unawaited(_arrived?.cancel());
    unawaited(_offers?.cancel());
    _cooldown?.cancel();
    super.dispose();
  }

  /// Follows the messaging service for arrived text.
  ///
  /// Watched rather than read, for the same reason every other follower in this
  /// app watches: a new listen port builds a new service, and a subscription
  /// left on the old one listens to a stream nothing will ever write to again.
  void _followLan(LanService? service) {
    if (identical(service, _watchedLan)) {
      return;
    }
    _watchedLan = service;
    unawaited(_arrived?.cancel());
    _arrived = service?.messagesArrived.listen((String _) => _ring());
  }

  /// Follows the transfer engine for arrived files and folders.
  void _followTransfers(TransferService? service) {
    if (identical(service, _watchedTransfers)) {
      return;
    }
    _watchedTransfers = service;
    unawaited(_offers?.cancel());
    _offers = service?.offers.listen((Transfer _) => _ring());
  }

  /// Rings once, unless the user asked not to be told or just was.
  ///
  /// The setting is read here rather than watched, so it governs the *next*
  /// message: a switch flipped while a message is being announced should not
  /// retroactively cancel the announcement already under way.
  void _ring() {
    if (!ref.read(settingsProvider).notificationsEnabled) {
      return;
    }
    if (_cooldown?.isActive ?? false) {
      return;
    }
    _cooldown = Timer(kChimeCooldown, () {});
    unawaited(NotificationSound.play());
  }

  @override
  Widget build(BuildContext context) {
    _followLan(ref.watch(lanServiceProvider).valueOrNull);
    _followTransfers(ref.watch(transferServiceProvider).valueOrNull);
    return widget.child;
  }
}
