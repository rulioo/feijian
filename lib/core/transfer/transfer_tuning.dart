import '../constants.dart';

/// The timings and sizes the transfer session runs on, gathered in one place.
///
/// The same reasoning as [TransportTuning]: behaviour that only shows up on a
/// timer or on the four-thousandth chunk is exactly the behaviour that rots
/// unnoticed. Passing these in lets a test drive an unanswered offer, a
/// mid-transfer cancel or a progress checkpoint in a fraction of a second with
/// a few kilobytes, over real sockets and a real database, instead of waiting a
/// minute or mocking the parts that are interesting.
///
/// Defaults are the real design values (design.md appendix B), so production
/// code passes nothing and tests pass their own.
class TransferTuning {
  const TransferTuning({
    this.offerTimeout = kOfferTimeout,
    this.receiptTimeout = kTransferReceiptTimeout,
    this.chunkSize = kChunkSize,
    this.persistEvery = kTransferPersistBytes,
  });

  /// How long an offer waits for the peer to accept or decline it.
  final Duration offerTimeout;

  /// How long a sender waits for the receiver's `file_done` after the last byte.
  final Duration receiptTimeout;

  /// How much of the file is read at a time.
  final int chunkSize;

  /// How many bytes move between writes of the `transfer` row.
  final int persistEvery;
}
