import '../protocol/frame_codec.dart';

/// Somewhere frames can be written, with backpressure.
///
/// Exists so the sender's read loop can be driven by a test without a socket.
/// What that loop has to get right is the *cadence* — read a chunk, write it,
/// flush every couple of megabytes — and a real TCP connection is a poor
/// instrument for observing it: the bytes go to the OS, and whether the flush
/// happened when it should is not something the far end can report.
///
/// [ControlConnection] is the only production implementation.
abstract interface class FrameSink {
  /// Writes [frame], reporting whether it went out.
  ///
  /// False means the connection is not writable; the caller must treat whatever
  /// the frame carried as unsent rather than assuming it is on its way.
  bool send(Frame frame);

  /// Waits for everything written so far to reach the OS.
  ///
  /// This is where backpressure actually lives: until it completes, the caller
  /// is holding the bytes, so a loop that flushes periodically cannot outrun the
  /// network no matter how large the file is.
  Future<void> flush();
}
