/// Where a connection is in its lifecycle — design.md §4.4.
enum ConnectionState {
  /// No socket. Either nothing has been tried yet, or the last attempt ended.
  idle,

  /// An outbound socket is being opened.
  connecting,

  /// The socket is up and `hello` is being exchanged. Nothing else may be sent
  /// until this finishes: the peer does not know who we are yet, and a `msg`
  /// arriving first would have no conversation to belong to.
  handshaking,

  /// `hello` went both ways.
  ready,

  /// Finished, for any reason — a clean `bye`, a socket error, a failed
  /// handshake, or the idle timeout.
  closed;

  /// Whether frames may be written right now.
  bool get isWritable => this == ConnectionState.ready;
}

/// Why a connection ended, for the log and for deciding whether to retry.
///
/// Worth distinguishing because the responses differ: a refused connection
/// means the peer is not listening (retry later, quietly), while a framing
/// error means the peer is speaking something that is not this protocol
/// (retrying will not help).
enum ConnectionClosedReason {
  /// A `bye` was exchanged, or we closed it deliberately.
  localBye,

  /// The peer sent `bye`, or closed its end cleanly.
  remoteBye,

  /// The socket reported an error. On Windows this is usually a refused
  /// connection, meaning nothing is listening on the peer's port.
  socketError,

  /// The peer sent bytes that cannot be frames — a protocol mismatch, or
  /// something that is not Feijian at all answering on this port.
  protocolError,

  /// No `hello` arrived within `kHandshakeTimeout`. Anyone on the LAN can open
  /// a connection, so one that says nothing is dropped rather than held.
  handshakeTimeout,

  /// Nothing at all arrived for `kConnectionIdleTimeout`, heartbeats included.
  /// A TCP connection can stay half-open indefinitely after the peer's network
  /// disappears, and only an application-level silence detector notices.
  idleTimeout,
}
