import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/message.dart';
import '../core/models/peer.dart';
import '../data/dao/message_dao.dart';
import '../data/repository/chat_repository.dart';
import 'data_providers.dart';
import 'lan_provider.dart';
import 'lan_service.dart';
import 'providers.dart';

/// What a conversation looks like to the chat page — design.md §6.3.
///
/// [messages] is **oldest first**, the order the page renders top to bottom.
/// That is the reverse of what the database returns, and the reversal happens
/// once, here, rather than in the widget: a list that has to reverse on every
/// build is a list that cannot be compared cheaply for "did anything change".
class ChatState {
  const ChatState({
    this.messages = const <Message>[],
    this.oldest,
    this.hasMore = false,
    this.loadingOlder = false,
    this.draft,
  });

  final List<Message> messages;

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
    MessageCursor? oldest,
    bool? hasMore,
    bool? loadingOlder,
    String? draft,
    bool clearDraft = false,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
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

  Timer? _draftTimer;

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
    ref.onDispose(() {
      _draftTimer?.cancel();
      unawaited(changes?.cancel());
    });

    // A conversation the user opened is a device worth being connected to, even
    // if it stopped announcing a while ago.
    final Peer? peer = ref.read(selectedPeerProvider);
    if (peer != null && peer.id == peerId) {
      service?.ensureConnected(peer);
    }

    final List<Message> newest = await _chat.page(peerId);
    final String? draft = await _chat.draftFor(peerId);
    await _chat.markRead(peerId);

    return ChatState(
      messages: newest.reversed.toList(growable: false),
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
  Future<void> deleteMessage(String msgId) async {
    final int removed = await _chat.deleteMessage(msgId);
    if (removed == 0) {
      return;
    }
    final ChatState? current = state.valueOrNull;
    if (current == null) {
      return;
    }
    state = AsyncData<ChatState>(
      current.copyWith(
        messages: current.messages
            .where((Message m) => m.id != msgId)
            .toList(growable: false),
      ),
    );
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
  Future<void> clearHistory() async {
    await _chat.clearHistory(peerId);
    state = AsyncData<ChatState>(ChatState(draft: state.valueOrNull?.draft));
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

    // The list may have been refreshed while this page was in flight; merge into
    // whatever is there now rather than overwriting it.
    final ChatState latest = state.valueOrNull ?? current;
    state = AsyncData<ChatState>(
      latest.copyWith(
        messages: _merge(older, latest.messages, const <Message>[]),
        // The cursor only ever moves backwards.
        oldest: ChatRepository.cursorBefore(older) ?? latest.oldest,
        hasMore: older.length == ChatRepository.kPageSize,
        loadingOlder: false,
      ),
    );
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
    final String? anchor = current.messages.isEmpty
        ? null
        : current.messages.first.id;
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

    final ChatState latest = state.valueOrNull ?? current;
    state = AsyncData<ChatState>(
      latest.copyWith(
        messages: _merge(const <Message>[], latest.messages, fetched),
        // Keep the furthest-back position reached; a refresh never loses
        // pagination the user has already paid for.
        oldest: _olderOf(latest.oldest, ChatRepository.cursorBefore(fetched)),
      ),
    );
    await _chat.markRead(peerId);
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

/// Unread counts by peer id, for the badges on the device list (§6.2).
///
/// Re-read as a whole rather than patched per event: the map is small, and a
/// count that is recomputed from the database cannot drift away from it the way
/// an incremented one can.
final StreamProvider<Map<String, int>> unreadByPeerProvider =
    StreamProvider<Map<String, int>>((Ref ref) {
  final ChatRepository chat = ref.watch(chatRepositoryProvider);
  final LanService? service = ref.watch(lanServiceProvider).valueOrNull;
  final StreamController<Map<String, int>> out =
      StreamController<Map<String, int>>();

  Future<void> emit() async {
    if (out.isClosed) {
      return;
    }
    out.add(await chat.unreadByPeer());
  }

  final StreamSubscription<String>? changes =
      service?.messagesChanged.listen((String _) => unawaited(emit()));

  ref.onDispose(() {
    unawaited(changes?.cancel());
    unawaited(out.close());
  });

  // Once for the counts that already exist, before anything new arrives.
  unawaited(emit());
  return out.stream;
});
