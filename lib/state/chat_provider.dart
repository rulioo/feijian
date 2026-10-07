import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/message.dart';
import '../core/models/peer.dart';
import '../core/models/transfer.dart';
import '../data/dao/message_dao.dart';
import '../data/repository/chat_repository.dart';
import '../data/repository/transfer_repository.dart';
import 'data_providers.dart';
import 'lan_provider.dart';
import 'lan_service.dart';
import 'providers.dart';
import 'transfer_provider.dart';
import 'transfer_service.dart';

/// What a conversation looks like to the chat page — design.md §6.3.
///
/// [messages] is **oldest first**, the order the page renders top to bottom.
/// That is the reverse of what the database returns, and the reversal happens
/// once, here, rather than in the widget: a list that has to reverse on every
/// build is a list that cannot be compared cheaply for "did anything change".
class ChatState {
  const ChatState({
    this.messages = const <Message>[],
    this.attachments = const <String, List<Attachment>>{},
    this.tasks = const <String, Transfer>{},
    this.oldest,
    this.hasMore = false,
    this.loadingOlder = false,
    this.draft,
  });

  final List<Message> messages;

  /// The files behind each message that has any, keyed by message id (§5.1).
  ///
  /// A list rather than one attachment, because a transferred folder is one
  /// message with many — and a map that held one would keep whichever the query
  /// happened to return last, which is a folder silently showing a single file
  /// out of nine. A single file's list holds one entry.
  ///
  /// Beside [messages] rather than on them, because a [Message] is the row the
  /// `message` table holds and an attachment is a different table's row. Text
  /// messages have no entry, which is not a gap to be filled — it is the answer
  /// to "is there a file here", and the bubble reads it that way.
  final Map<String, List<Attachment>> attachments;

  /// The live folder transfer behind each message that has one, keyed by message
  /// id.
  ///
  /// Only folders appear here. A single file's progress belongs to its
  /// attachment and is already in [attachments]; a folder's belongs to no
  /// single file, so it needs a home of its own. The [Transfer] is the same one
  /// the row holds, caught at its newest value — see the controller's `_live`.
  final Map<String, Transfer> tasks;

  /// Position of the oldest loaded message, for the next page back.
  final MessageCursor? oldest;

  /// Whether older history exists. False once a page comes back short — the
  /// only way to know, since nothing counts the messages a peer holds.
  final bool hasMore;

  final bool loadingOlder;

  /// Unsent text, restored from the database when the conversation opens.
  final String? draft;

  ChatState copyWith({
    List<Message>? messages,
    Map<String, List<Attachment>>? attachments,
    Map<String, Transfer>? tasks,
    MessageCursor? oldest,
    bool? hasMore,
    bool? loadingOlder,
    String? draft,
    bool clearDraft = false,
    bool clearAttachments = false,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      attachments: clearAttachments
          ? const <String, List<Attachment>>{}
          : attachments ?? this.attachments,
      tasks: clearAttachments ? const <String, Transfer>{} : tasks ?? this.tasks,
      oldest: oldest ?? this.oldest,
      hasMore: hasMore ?? this.hasMore,
      loadingOlder: loadingOlder ?? this.loadingOlder,
      draft: clearDraft ? null : draft ?? this.draft,
    );
  }
}

/// One conversation's history and its send/retry actions.
///
/// `autoDispose`, and that is load-bearing: while a conversation is open its
/// incoming messages are marked read, so a provider that stayed alive after the
/// page closed would keep marking new messages read and the unread badge would
/// never appear.
final AutoDisposeAsyncNotifierProviderFamily<ChatController, ChatState, String>
    chatProvider =
    AsyncNotifierProvider.autoDispose.family<ChatController, ChatState, String>(
  ChatController.new,
);

class ChatController extends AutoDisposeFamilyAsyncNotifier<ChatState, String> {
  late final ChatRepository _chat = ref.read(chatRepositoryProvider);

  /// Read separately from [_chat] because the attachments are a different
  /// table's rows, and the repository that owns their mapping is the transfer
  /// one. Composing the two into a page is this layer's job, not either
  /// repository's.
  late final TransferRepository _transfers = ref.read(
    transferRepositoryProvider,
  );

  Timer? _draftTimer;

  /// The newest state of every transfer this conversation has seen move, keyed
  /// by attachment id.
  ///
  /// Progress is the one thing about a transfer that is *not* in the database —
  /// §4.6.1 writes the row on a checkpoint rather than per chunk, because a 1 GB
  /// file would otherwise be four thousand writes — so a bubble that read only
  /// the row would advance in 2 MB steps. This is where the smooth value comes
  /// from.
  ///
  /// It outlives the transfer on purpose: the last emission is the ending, and
  /// dropping the entry when it finished would send the bubble back to a row the
  /// page may not have re-read yet.
  final Map<String, Transfer> _live = <String, Transfer>{};

  /// The newest state of every **folder** transfer, keyed by message id.
  ///
  /// A second map rather than a second kind of key in [_live], because the two
  /// are keyed by different things for a reason that is in the schema: a single
  /// file's attempt is named by its attachment, and a folder's attempt is named
  /// by nothing but the task itself — §4.6 rule 3 gives every file in it one
  /// `xferId`, so `transfer.attachment_id` is null and there is no attachment id
  /// to look it up by.
  ///
  /// The bytes here are the whole folder's, which is what its progress bar is
  /// measured against. Which of its files are done is read from their rows, not
  /// from here.
  final Map<String, Transfer> _liveTasks = <String, Transfer>{};

  /// Message ids whose row this controller has already gone looking for.
  ///
  /// A transfer reports itself before the chat page knows its message exists —
  /// the message is written by the transfer layer, and the page learns about new
  /// messages through a channel transfers do not use. So the first mention of an
  /// unknown message is answered with a re-read; without this set, every chunk
  /// of that same transfer would ask again, and a 1 GB file would be eight
  /// thousand page queries.
  final Set<String> _lookedFor = <String>{};

  String get peerId => arg;

  @override
  Future<ChatState> build(String arg) async {
    // Rebuilds the page when this peer's history changes — a message arriving,
    // a tick turning into two. The event carries no payload; the database is the
    // source of truth and the event only says "look again".
    final LanService? service = ref.watch(lanServiceProvider).valueOrNull;
    final StreamSubscription<String>? changes = service?.messagesChanged
        .where((String id) => id == peerId)
        .listen((String _) => unawaited(refresh()));

    // The transfer engine, for the two things the database cannot say in time:
    // how far a file has got, and that a file exists at all. Watched rather than
    // read, so a rebuilt engine — a new listen port, a new manager — replaces
    // this subscription instead of leaving it on a disposed stream.
    final TransferService? transfers =
        ref.watch(transferServiceProvider).valueOrNull;
    final StreamSubscription<Transfer>? moving = transfers?.changes
        .where((Transfer t) => t.peerId == peerId)
        .listen(_onTransferChanged);

    ref.onDispose(() {
      _draftTimer?.cancel();
      unawaited(changes?.cancel());
      unawaited(moving?.cancel());
    });

    // A conversation the user opened is a device worth being connected to, even
    // if it stopped announcing a while ago.
    final Peer? peer = ref.read(selectedPeerProvider);
    if (peer != null && peer.id == peerId) {
      service?.ensureConnected(peer);
    }

    final List<Message> newest = await _chat.page(peerId);
    final Iterable<String> ids = newest.map((Message m) => m.id);
    final Map<String, List<Attachment>> attachments =
        await _transfers.attachmentsForMessages(ids);
    final Map<String, Transfer> tasks = await _tasksOf(newest);
    final String? draft = await _chat.draftFor(peerId);
    await _markRead();

    return ChatState(
      messages: newest.reversed.toList(growable: false),
      attachments: attachments,
      tasks: tasks,
      oldest: ChatRepository.cursorBefore(newest),
      hasMore: newest.length == ChatRepository.kPageSize,
      draft: draft,
    );
  }

  /// Sends [text] to the peer.
  ///
  /// Returns immediately after the message is stored: delivery is the queue's
  /// job, and §4.4.1 measured a failed connect at about two seconds on Windows,
  /// so waiting on the network here would freeze the page whenever the peer is
  /// away. The new bubble appears as `pending` and advances on its own.
  Future<void> send(String text) async {
    final String body = text.trim();
    if (body.isEmpty) {
      return;
    }
    final LanService? service = ref.read(lanServiceProvider).valueOrNull;
    if (service == null) {
      // The router could not start (the port is taken, most likely). Sending
      // anyway would store a message nothing can ever deliver.
      throw StateError('messaging is unavailable: the network service is down');
    }

    await service.sendText(peerId: peerId, text: body);
    // Sending clears the draft, so the composer starts empty next time.
    await setDraft('');
  }

  /// Puts a failed message back in the queue.
  Future<void> retry(String msgId) async {
    final LanService? service = ref.read(lanServiceProvider).valueOrNull;
    if (service == null) {
      return;
    }
    await service.retryMessage(peerId, msgId);
  }

  /// Drops one message from this device — §6.3's 「删除本地记录」.
  ///
  /// Removed from the loaded window by hand rather than by refreshing: a refresh
  /// re-reads pages from the database to keep the window contiguous, and the
  /// message is simply gone, so there is nothing to reconcile. It also keeps the
  /// user's scroll position, which a refresh would not.
  ///
  /// A `pending` message deleted here is a debt the peer will never be paid, and
  /// that is the intent — deleting it is how the user cancels a send.
  /// Returns whether the row was actually removed.
  ///
  /// The answer is the caller's, not a detail: the bubble puts its toast up on
  /// the strength of it. A `false` here used to be indistinguishable from a
  /// success at the call site, which is how the app spent a release telling
  /// users a file message had been deleted while SQLite refused to delete it.
  Future<bool> deleteMessage(String msgId) async {
    final int removed = await _chat.deleteMessage(msgId);
    if (removed == 0) {
      return false;
    }
    final ChatState? current = state.valueOrNull;
    if (current == null) {
      // Nothing loaded to take it out of — the row is gone either way, and the
      // next read will not find it.
      return true;
    }
    final Map<String, List<Attachment>> attachments =
        Map<String, List<Attachment>>.of(current.attachments)..remove(msgId);
    state = AsyncData<ChatState>(
      current.copyWith(
        messages: current.messages
            .where((Message m) => m.id != msgId)
            .toList(growable: false),
        attachments: attachments,
      ),
    );
    return true;
  }

  /// Empties the conversation, keeping the device and the draft.
  ///
  /// Built as a fresh state rather than a `copyWith`, because `oldest` has to go
  /// back to null and `copyWith` cannot distinguish "leave it" from "clear it".
  /// A stale cursor is not harmless: `hasMore` is false so nothing would fetch,
  /// but the next `loadOlder` after new messages arrive would page from a
  /// position the conversation no longer has.
  ///
  /// The draft is carried over deliberately — it is text the user has typed and
  /// can still see in the composer, and `MessageDao.clearIn` leaves its row
  /// alone for the same reason.
  ///
  /// Returns how many messages went. The state is replaced only after the write
  /// returns: an exception out of the transaction used to leave the old state in
  /// place — which is correct, and exactly why the page has to catch it rather
  /// than show a snackbar from the line below as if nothing had gone wrong.
  Future<int> clearHistory() async {
    final int removed = await _chat.clearHistory(peerId);
    // The attachments go with the messages they belong to. A map that kept them
    // would be holding rows for messages this conversation no longer has, and
    // the next refresh would look them up by ids that are gone.
    state = AsyncData<ChatState>(ChatState(draft: state.valueOrNull?.draft));
    return removed;
  }

  /// Loads the page of history older than what is on screen.
  Future<void> loadOlder() async {
    final ChatState? current = state.valueOrNull;
    if (current == null || current.loadingOlder || !current.hasMore) {
      return;
    }
    state = AsyncData<ChatState>(current.copyWith(loadingOlder: true));

    final List<Message> older = await _chat.page(
      peerId,
      before: current.oldest,
      limit: ChatRepository.kPageSize,
    );
    final Map<String, List<Attachment>> attachments = await _attachmentsOf(older);
    final Map<String, Transfer> tasks = await _tasksOf(older);

    // The list may have been refreshed while this page was in flight; merge into
    // whatever is there now rather than overwriting it.
    final ChatState latest = state.valueOrNull ?? current;
    state = AsyncData<ChatState>(
      latest.copyWith(
        messages: _merge(older, latest.messages, const <Message>[]),
        attachments: <String, List<Attachment>>{
          ...latest.attachments,
          ...attachments,
        },
        tasks: <String, Transfer>{...latest.tasks, ...tasks},
        // The cursor only ever moves backwards.
        oldest: ChatRepository.cursorBefore(older) ?? latest.oldest,
        hasMore: older.length == ChatRepository.kPageSize,
        loadingOlder: false,
      ),
    );
  }

  /// The attachments behind [messages], in the shape [ChatState] holds them.
  ///
  /// A refresh reads up to [_maxRefreshPages] pages in a loop and then attaches
  /// them in one go rather than one page at a time: the messages are merged into
  /// a map keyed by id, and asking per page would be the same query split into
  /// eight.
  Future<Map<String, List<Attachment>>> _attachmentsOf(
    List<Message> messages,
  ) async {
    final Map<String, List<Attachment>> stored = await _transfers
        .attachmentsForMessages(messages.map((Message m) => m.id));
    return <String, List<Attachment>>{
      for (final MapEntry<String, List<Attachment>> entry in stored.entries)
        entry.key: entry.value.map(_withLive).toList(growable: false),
    };
  }

  /// The folder tasks behind [messages], with the live value folded in.
  ///
  /// The same shape as [_attachmentsOf] and for the same reasons — one query for
  /// a whole page, and the live entry winning over the row so a bar does not go
  /// backwards — but a different subject: this is about the *task*, which for a
  /// folder is the only place its byte count exists at all.
  Future<Map<String, Transfer>> _tasksOf(List<Message> messages) async {
    final Map<String, Transfer> stored =
        await _transfers.tasksForMessages(messages.map((Message m) => m.id));
    return <String, Transfer>{
      for (final MapEntry<String, Transfer> entry in stored.entries)
        entry.key: _liveTasks[entry.key] ?? entry.value,
    };
  }

  /// [attachment], with the live transfer folded in if there is one.
  ///
  /// Without this the progress bar goes backwards. The row is written every
  /// couple of megabytes, so a refresh triggered by an unrelated message — a
  /// text arriving mid-transfer — reads a value that is seconds behind what is
  /// on screen, and a bar at 40% would drop to 32% for no reason the user can
  /// see.
  ///
  /// The live value always wins rather than the newer of the two: there is no
  /// timestamp on an [Attachment] to compare, and the service is the thing
  /// writing the row, so nothing it has not reported can be ahead of it. Once a
  /// transfer ends the service stops reporting, and the last thing it reported
  /// was the ending — which is also what the row says by then.
  Attachment _withLive(Attachment attachment) {
    final Transfer? live = _live[attachment.id];
    if (live == null) {
      return attachment;
    }
    return attachment.copyWith(
      state: live.state,
      transferred: live.bytesDone,
    );
  }

  void _onTransferChanged(Transfer transfer) {
    final String? attachmentId = transfer.attachmentId;
    if (attachmentId == null) {
      _onTaskChanged(transfer);
      return;
    }
    _live[attachmentId] = transfer;

    final ChatState? current = state.valueOrNull;
    if (current == null) {
      return;
    }
    final String? messageId = transfer.messageId;
    if (messageId == null) {
      return;
    }
    final List<Attachment>? files = current.attachments[messageId];
    if (files == null || files.isEmpty) {
      // A file the page has not loaded: either brand new, or older than the
      // window the user has scrolled to. Asked about once per id — see
      // [_lookedFor] — because the alternative is a page query per 256 KB.
      if (_lookedFor.add(messageId)) {
        unawaited(refresh());
      }
      return;
    }

    state = AsyncData<ChatState>(
      current.copyWith(
        attachments: <String, List<Attachment>>{
          ...current.attachments,
          messageId: files.map(_withLive).toList(growable: false),
        },
      ),
    );

    if (transfer.isFinished) {
      unawaited(_rereadAttachments(messageId));
    }
  }

  /// Re-reads one message's attachments from their rows.
  ///
  /// The live transfer carries the two values a progress bar needs and stops
  /// there — and `local_path` is not one of them, because a [Transfer] has no
  /// such field at all. It is written to the **attachment** row, by
  /// `TransferRepository.finish` on the receiving side, so a transfer that has
  /// just ended leaves a path in the database and none in the state the page is
  /// drawing from: every bubble keeps showing whatever it showed while the bytes
  /// were moving.
  ///
  /// For a picture that is the whole bug. A moving image is drawn as a file card
  /// — a thumbnail that is a quarter painted reads as a corrupt photo — and
  /// nothing short of a re-read moves it from that card to the picture, so a
  /// received photo arrived and stayed a card until some unrelated event
  /// happened to refresh the page.
  ///
  /// Once per ending rather than once per chunk: the caller asks only when the
  /// transfer is [Transfer.isFinished].
  Future<void> _rereadAttachments(String messageId) async {
    final Map<String, List<Attachment>> stored = await _transfers
        .attachmentsForMessages(<String>[messageId]);
    final List<Attachment>? files = stored[messageId];
    // Merged into whatever is on screen now rather than into the state this
    // started from: the read is a round trip, and the page may have moved on.
    final ChatState? latest = state.valueOrNull;
    if (files == null || latest == null) {
      return;
    }
    state = AsyncData<ChatState>(
      latest.copyWith(
        attachments: <String, List<Attachment>>{
          ...latest.attachments,
          messageId: files.map(_withLive).toList(growable: false),
        },
      ),
    );
  }

  /// A **folder** task moving, which has no attachment of its own to hang on.
  ///
  /// The whole of the difference from the single-file path above is where the
  /// value goes: a folder's bytes are the task's, so they land in [ChatState.tasks]
  /// against the message, and each file's own state is written to its row as
  /// that file lands rather than folded in here.
  void _onTaskChanged(Transfer transfer) {
    final String? messageId = transfer.messageId;
    if (messageId == null) {
      // A transfer with neither an attachment nor a message is a row nothing on
      // screen can be about — §5.1 leaves both references nullable so a transfer
      // can outlive a cleared history, and this is that case.
      return;
    }
    _liveTasks[messageId] = transfer;

    final ChatState? current = state.valueOrNull;
    if (current == null) {
      return;
    }
    if (!current.attachments.containsKey(messageId) &&
        !current.tasks.containsKey(messageId)) {
      // A folder the page has not loaded, for the same reasons as a file. Note
      // that a folder of nothing but empty directories has a task and no
      // attachments at all, so the check cannot be on attachments alone.
      if (_lookedFor.add(messageId)) {
        unawaited(refresh());
      }
      return;
    }

    state = AsyncData<ChatState>(
      current.copyWith(
        tasks: <String, Transfer>{...current.tasks, messageId: transfer},
      ),
    );

    if (transfer.isFinished) {
      // The task's own row is not the whole of it for a folder: every file's
      // path went onto *its* attachment row as it landed (§5.1.1), and those
      // rows are what the card offers Open on. The task ending is when the last
      // of them is written.
      unawaited(_rereadAttachments(messageId));
    }
  }

  /// Re-reads the history after something changed.
  ///
  /// Reads back as far as the user has already scrolled, not just the newest
  /// page: a status change on an old message — a queued message finally
  /// acknowledged — would otherwise never reach a bubble that is on screen.
  Future<void> refresh() async {
    final ChatState? current = state.valueOrNull;
    if (current == null) {
      return;
    }

    // Read pages until the oldest message already held turns up, so the window
    // grows with new arrivals instead of sliding and dropping history the user
    // has scrolled back to.
    final String? anchor =
        current.messages.isEmpty ? null : current.messages.first.id;
    final List<Message> fetched = <Message>[];
    MessageCursor? cursor;
    // Bounded: a conversation someone has been reading all day should not turn
    // one incoming message into an unbounded scan of the history.
    for (int page = 0; page < _maxRefreshPages; page++) {
      final List<Message> rows = await _chat.page(
        peerId,
        before: cursor,
        limit: ChatRepository.kPageSize,
      );
      fetched.addAll(rows);
      if (rows.isEmpty || rows.length < ChatRepository.kPageSize) {
        break;
      }
      if (anchor != null && rows.any((Message m) => m.id == anchor)) {
        break;
      }
      cursor = ChatRepository.cursorBefore(rows);
    }

    final Map<String, List<Attachment>> attachments =
        await _attachmentsOf(fetched);
    final Map<String, Transfer> tasks = await _tasksOf(fetched);
    final ChatState latest = state.valueOrNull ?? current;
    state = AsyncData<ChatState>(
      latest.copyWith(
        messages: _merge(const <Message>[], latest.messages, fetched),
        // Freshly read attachments win: a transfer that moved while this was in
        // flight has already written the newer row, and the read above is the
        // one that saw it.
        attachments: <String, List<Attachment>>{
          ...latest.attachments,
          ...attachments,
        },
        // Freshly read tasks win, for the same reason the attachments above are
        // in this order: `_tasksOf` has already folded the live value in, so
        // what it returns is never behind what the state holds. Spreading the
        // state last would overwrite it with the older value — and spreading the
        // state first still keeps a task for a message outside this window,
        // which is the only thing the merge is for.
        tasks: <String, Transfer>{...latest.tasks, ...tasks},
        // Keep the furthest-back position reached; a refresh never loses
        // pagination the user has already paid for.
        oldest: _olderOf(latest.oldest, ChatRepository.cursorBefore(fetched)),
      ),
    );
    await _markRead();
  }

  /// Clears this conversation's unread count, and says so.
  ///
  /// One method rather than two calls at each site, because the second half is
  /// the half that is easy to forget and the failure is invisible: the write
  /// lands, the database is right, and the badge keeps showing a number the user
  /// has already dealt with — with nothing on screen to suggest why.
  ///
  /// It is deliberately **not** `LanService.messagesChanged`: this controller
  /// listens to that stream, so announcing a read on it would refresh, which
  /// marks read, which announces again.
  Future<void> _markRead() async {
    await _chat.markRead(peerId);
    ref.read(chatEventsProvider).notify(peerId);
  }

  /// Remembers what is being typed, so switching devices does not lose it.
  ///
  /// Debounced: the composer calls this on every keystroke, and one row write
  /// per character is a lot of I/O for something read back only when the
  /// conversation is reopened.
  Future<void> setDraft(String text) async {
    final String? draft = text.isEmpty ? null : text;
    final ChatState? current = state.valueOrNull;
    if (current != null) {
      state = AsyncData<ChatState>(current.copyWith(draft: draft));
    }

    _draftTimer?.cancel();
    _draftTimer = Timer(_draftDebounce, () {
      unawaited(_chat.setDraft(peerId, draft));
    });
  }

  static const Duration _draftDebounce = Duration(milliseconds: 400);

  /// How far back a refresh will read to keep the loaded window contiguous.
  static const int _maxRefreshPages = 8;
}

/// The newest value of each message, in display order.
///
/// Later lists win, so passing the freshly read page last is what lets a status
/// change reach a bubble that is already on screen.
List<Message> _merge(
  List<Message> older,
  List<Message> current,
  List<Message> newer,
) {
  final Map<String, Message> byId = <String, Message>{};
  for (final List<Message> batch in <List<Message>>[older, current, newer]) {
    for (final Message message in batch) {
      byId[message.id] = message;
    }
  }
  final List<Message> merged = byId.values.toList();
  merged.sort(Message.compareOldestFirst);
  return merged;
}

/// The further back of two cursors — the one naming the older position.
MessageCursor? _olderOf(MessageCursor? a, MessageCursor? b) {
  if (a == null) {
    return b;
  }
  if (b == null) {
    return a;
  }
  if (a.createdAt != b.createdAt) {
    return a.createdAt < b.createdAt ? a : b;
  }
  return a.id.compareTo(b.id) <= 0 ? a : b;
}

/// The peers whose **local** chat state changed — the sibling of
/// [`LanService.messagesChanged`], and deliberately not the same stream.
///
/// The two say different things and only one of them may wake the chat page.
/// `messagesChanged` is what a *packet* did: a message was stored, a status
/// advanced. The chat page listens to it, re-reads, and that is correct. This
/// one is what the *user* did. Reading a conversation is the whole of it, and a
/// chat page that listened here would spin: reading marks read, marking read
/// announces, the announcement re-reads, and the re-read marks read again.
///
/// So it is a separate bus with one intended listener — the unread badge, which
/// needs both halves. A message arriving and a message being read both move the
/// count, and the badge hanging off only the first is the bug that put a 2 over
/// a conversation the user had already opened.
class ChatEvents {
  final StreamController<String> _changed = StreamController<String>.broadcast();

  /// Broadcast and not replayed, for the same reason as `messagesChanged`: a
  /// listener that missed an event reads the current state from the database
  /// anyway, so a fresh listener loses nothing.
  Stream<String> get changed => _changed.stream;

  void notify(String peerId) {
    if (!_changed.isClosed) {
      _changed.add(peerId);
    }
  }

  Future<void> dispose() => _changed.close();
}

final Provider<ChatEvents> chatEventsProvider = Provider<ChatEvents>((Ref ref) {
  final ChatEvents events = ChatEvents();
  ref.onDispose(events.dispose);
  return events;
});

/// Unread counts by peer id, for the badges on the device list (§6.2).
///
/// Re-read as a whole rather than patched per event: the map is small, and a
/// count that is recomputed from the database cannot drift away from it the way
/// an incremented one can.
final StreamProvider<Map<String, int>> unreadByPeerProvider =
    StreamProvider<Map<String, int>>((Ref ref) {
  final ChatRepository chat = ref.watch(chatRepositoryProvider);
  final LanService? service = ref.watch(lanServiceProvider).valueOrNull;
  final ChatEvents events = ref.watch(chatEventsProvider);
  final StreamController<Map<String, int>> out =
      StreamController<Map<String, int>>();

  Future<void> emit() async {
    if (out.isClosed) {
      return;
    }
    out.add(await chat.unreadByPeer());
  }

  // Both halves, and neither is optional: a count that ignores arrivals never
  // rises, and one that ignores reads never falls.
  final StreamSubscription<String>? arrived =
      service?.messagesChanged.listen((String _) => unawaited(emit()));
  final StreamSubscription<String> read =
      events.changed.listen((String _) => unawaited(emit()));

  ref.onDispose(() {
    unawaited(arrived?.cancel());
    unawaited(read.cancel());
    unawaited(out.close());
  });

  // Once for the counts that already exist, before anything new arrives.
  unawaited(emit());
  return out.stream;
});
