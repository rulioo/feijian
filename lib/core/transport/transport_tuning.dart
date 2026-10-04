import '../constants.dart';

/// The timeouts and retry limits the transport runs on, gathered in one place.
///
/// These are constructor arguments rather than direct reads of the constants
/// for one reason: several of them are tens of seconds, and behaviour that only
/// shows up on a timer is exactly the behaviour that rots unnoticed. Passing
/// them in lets a test drive a handshake timeout or an ack retry in a tenth of
/// a second over a real socket, instead of either waiting forty seconds or
/// mocking the socket and testing nothing.
///
/// Defaults are the real design values (design.md appendix B), so production
/// code passes nothing and tests pass their own.
class TransportTuning {
  const TransportTuning({
    this.handshakeTimeout = kHandshakeTimeout,
    this.idleTimeout = kConnectionIdleTimeout,
    this.connectTimeout = kConnectTimeout,
    this.closeFlushTimeout = kCloseFlushTimeout,
    this.ackTimeout = kMsgAckTimeout,
    this.maxRetries = kMsgMaxRetries,
    this.backoff = kReconnectBackoff,
  });

  /// How long an incoming connection has to produce its `hello`.
  final Duration handshakeTimeout;

  /// Silence longer than this means the connection is dead even though TCP
  /// has not noticed.
  final Duration idleTimeout;

  /// How long an outbound connect attempt has before it is abandoned.
  final Duration connectTimeout;

  /// How long a closing `bye` gets to reach the OS.
  final Duration closeFlushTimeout;

  /// How long to wait for an `msg_ack` before resending.
  final Duration ackTimeout;

  /// Resends before a message is reported as failed.
  final int maxRetries;

  /// Wait before each successive reconnect attempt.
  final List<Duration> backoff;

  /// The wait before reconnect attempt number [attempt], counting from zero.
  ///
  /// Clamps at the last entry, so the schedule degrades to a fixed interval
  /// rather than growing without bound: a peer that has been off for an hour
  /// should be retried every thirty seconds, not every four hours.
  /// An empty schedule is a programming error rather than something to work
  /// around, so it is reported loudly instead of silently retrying with no wait.
  /// It cannot be an assert on the constructor — Dart cannot read a list's
  /// length in a const expression, and this class has to stay const to be a
  /// default argument.
  Duration backoffFor(int attempt) {
    if (backoff.isEmpty) {
      throw StateError('TransportTuning.backoff is empty');
    }
    if (attempt < 0) {
      return backoff.first;
    }
    final int index = attempt < backoff.length ? attempt : backoff.length - 1;
    return backoff[index];
  }
}
