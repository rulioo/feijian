/// Protocol and runtime constants — design.md appendix B.
///
/// This file is the single source of truth for every magic number that appears
/// on the wire or in a timeout. Nothing here may import `package:flutter/*`:
/// the whole `core/` layer stays pure Dart so it can be unit-tested without an
/// emulator (design.md §3.1).
library;

/// Bumped only on a breaking wire-format change. Peers that disagree ignore
/// each other's announces and log it rather than guessing (design.md §4.1).
const int kProtocolVersion = 1;

/// Single port for both discovery (UDP) and transport (TCP) — design.md §4.4.
///
/// Deliberately not 2425, the port 飞鸽传书 / IP Messenger uses, so that
/// installing both tools on one machine does not produce a port conflict.
const int kDiscoveryPort = 24250;

/// Multicast group inside the IPv4 administratively-scoped range (239/8),
/// chosen to avoid colliding with mDNS (224.0.0.251) and SSDP (239.255.255.250).
const String kMulticastGroup = '239.255.42.50';

/// Sent in addition to multicast: some enterprise APs silently drop multicast,
/// so the broadcast path is what keeps those networks working (design.md §4.1).
const String kBroadcastAddress = '255.255.255.255';

/// mDNS service type, reserved for the iOS/Bonjour discovery path (design.md §7.3).
const String kMdnsServiceType = '_feijian._tcp';

// --- Discovery timing -------------------------------------------------------

const Duration kAnnounceInterval = Duration(seconds: 5);

/// Heartbeat rounds between the periodic probes — six rounds, 30s.
///
/// A plain announce is multicast and broadcast, and on a network where either
/// of those has quietly stopped arriving, this device becomes invisible to
/// peers that could still reach it perfectly well by unicast. That is what a
/// manual refresh produces and why pressing it works when waiting does not: a
/// **probe** is the one packet in this protocol that reliably draws a unicast
/// answer out of every peer that hears it. Sending one now and then is what
/// keeps the list honest on a network where the send direction is not the
/// problem. Unicast is not free of cost, so this is deliberately slow — each
/// probe costs one packet per peer on the LAN.
const int kProbeEveryRounds = 6;

/// Rounds of probe-and-announce a device sends on coming up, and the gap
/// between them.
///
/// One datagram is a coin flip: Windows drops roughly 4% of UDP sent back to
/// back on a real NIC and reports it only as a 0-byte write, and a Wi-Fi access
/// point may drop a broadcast outright. A device that has just joined the
/// network gets one moment to introduce itself, and it is the moment its owner
/// is watching. The same shape, and the same numbers, as the rounds a manual
/// refresh sends.
const int kStartBurstRounds = 3;
const Duration kStartBurstGap = Duration(milliseconds: 400);

/// No packet for this long → grey the peer out but keep the conversation readable.
const Duration kPeerOfflineAfter = Duration(seconds: 15);

/// How long *every* peer this device has heard from may stay silent before
/// discovery stops waiting and rebuilds itself — the watchdog.
///
/// Four announce intervals, and deliberately just past [kPeerOfflineAfter]: by
/// the time this fires the list is already visibly grey, so the repair lands
/// while the user is still looking at the symptom rather than after they have
/// given up on it.
///
/// This is the third and last of the ways a device goes invisible, and the only
/// one that needs no one else's cooperation to fix. A multicast membership the
/// kernel dropped, a listening socket that has quietly stopped delivering, an
/// interface that was reset underneath us — none of those produce an error, and
/// none of them are repaired by announcing more loudly, because the broken
/// direction is the one pointing at us. Rebuilding the sockets is what a manual
/// refresh does, and this is that, without the manual part.
///
/// It cannot fire before [kPeerRemoveAfter] has emptied the table of a peer
/// that really has gone away: inside that window a peer that left is still
/// listed, so "everyone has gone quiet" is also true of a network where nothing
/// is wrong. That is what the one-repair-per-silence rule in the service is
/// for — one rebuild, not one every second, and no second attempt until
/// something is heard again.
const Duration kSilentPeerRebindAfter = Duration(seconds: 20);

/// No packet for this long → drop from the device list (the DB row survives).
const Duration kPeerRemoveAfter = Duration(seconds: 60);

/// Announces whose `ts` is further than this from our own clock are dropped.
/// They are either stale (queued behind a network stall) or from a device whose
/// clock is badly wrong — either way the packet says nothing trustworthy about
/// "now", and it is `ts` that decides whether a peer counts as online.
///
/// Deliberately generous: two consumer devices on a LAN routinely disagree by
/// seconds, and a tight window would silently break discovery between two
/// perfectly healthy machines. This bounds the damage, it does not sync clocks.
const Duration kAnnounceMaxClockSkew = Duration(seconds: 60);

/// Longest accepted display name. Anything longer cannot be rendered anyway,
/// and the cap keeps one peer's name from crowding the rest of the fields out
/// of the 1400-byte datagram budget.
const int kMaxDeviceNameLength = 64;

/// Longest accepted device id. A UUIDv4 is 36 characters; the headroom is for
/// a future id format, not for unbounded input from the network.
const int kMaxDeviceIdLength = 64;

// --- Connection timing ------------------------------------------------------

const Duration kHeartbeatInterval = Duration(seconds: 30);

/// Exponential backoff for reconnect attempts: the wait after the first
/// failure, the second, and so on. The last entry repeats for every attempt
/// after it, which is what keeps a peer that is gone for the afternoon from
/// being dialled every second until it comes back.
const List<Duration> kReconnectBackoff = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 30),
];

/// How long to wait for an incoming `hello` before dropping a fresh socket.
/// Without this, anyone on the LAN can hold connections open by connecting
/// and staying silent.
const Duration kHandshakeTimeout = Duration(seconds: 10);

/// No bytes at all for this long → treat the connection as dead.
///
/// Three missed heartbeats. TCP will happily keep a connection "open" forever
/// after the peer's network vanishes — a laptop lid closing, a Wi-Fi drop, a
/// NAT entry expiring — because nothing is ever sent to trigger a reset. An
/// application-level silence detector is the only thing that notices, and
/// without one the peer list keeps showing a device that is long gone.
const Duration kConnectionIdleTimeout = Duration(seconds: 90);

/// How long an outbound connection has to be established before giving up.
/// Without it a dropped SYN leaves the attempt hanging for the OS default,
/// which on Windows is over 20 seconds.
const Duration kConnectTimeout = Duration(seconds: 8);

/// How long to wait for a closing `bye` to reach the OS before tearing the
/// socket down. `destroy()` discards buffered bytes, so the goodbye has to be
/// flushed first — but only briefly, since a connection is often closed
/// precisely because the peer has stopped answering.
const Duration kCloseFlushTimeout = Duration(seconds: 2);

// --- Framing (design.md §4.2) ----------------------------------------------

/// File data chunk size. Larger chunks mean fewer frames but a bigger stall
/// when one is lost; 256 KB is the balance point we test against.
const int kChunkSize = 256 * 1024;

/// Hard cap on a frame's JSON header. Exceeding it means the stream is corrupt
/// or hostile, so the connection is dropped instead of allocating (design.md §4.2).
const int kMaxFrameHeader = 1024 * 1024;

/// Hard cap on a single frame's binary payload.
const int kMaxPayload = 512 * 1024;

/// Simultaneous file transfers before new ones queue.
const int kMaxConcurrentXfers = 3;

/// Longest accepted `xferId`. Same shape as a device id and bounded for the
/// same reason — it is an opaque identifier from the network, and nothing on
/// the wire may be unbounded.
const int kMaxXferIdLength = 64;

/// Longest accepted file name in a `file_offer`.
///
/// Well past any real name, because [SafeName] truncates to what the file
/// system will take anyway. This is the hostile-input bound: the name travels
/// in the frame header, so without a cap one peer could put a megabyte there.
const int kMaxFileNameLength = 512;

/// How many directory levels a folder transfer may nest.
///
/// Deeper than any folder a person sends, and low enough that a hostile peer
/// cannot make the receiver build a directory tree that costs more to create —
/// and to remove again — than the transfer is worth. A path that goes deeper
/// refuses the whole offer rather than being flattened, because flattening
/// collapses two files onto one name, which is silent data loss (design.md §4.6).
const int kMaxPathDepth = 32;

/// Longest accepted `relPath` in a folder transfer, in UTF-8 bytes.
///
/// The manifest has its own byte ceiling (§4.6 rule 5), but a single path that
/// spent the whole of it would be a receiver creating nested directories until
/// the file system refused — and on Windows that refusal comes from MAX_PATH,
/// long after the offer was accepted.
const int kMaxRelPathLength = 1024;

/// Ceiling on a folder's manifest, in UTF-8 bytes of its JSON — design.md §4.6
/// rule 5.
///
/// The manifest travels in one `file_offer` header, so it is bounded by
/// [kMaxFrameHeader] whether anyone likes it or not; this is the bound the user
/// is told about. Past it the sender refuses to offer the folder at all and says
/// why, rather than sending a manifest that describes some of the folder —
/// a transfer that arrives looking complete while quietly missing files is the
/// worst of the three possible answers.
const int kMaxManifestBytes = 256 * 1024;

/// Longest accepted MIME type. A type string is a few dozen characters; the
/// headroom is for parameters (`text/plain; charset=utf-8`).
const int kMaxMimeLength = 255;

/// How long a `file_reject.reason` code may be. Codes, not sentences — see
/// [RejectReason].
const int kMaxRejectReasonLength = 32;

/// How much file data to write between `flush()` calls — design.md §4.6.
///
/// The sender reads and writes one [kChunkSize] at a time, but the socket
/// buffers what it is given and returns immediately. Without a periodic flush
/// there is nothing pushing back on the read loop, and the whole file ends up
/// resident in the socket's buffer: a 4 GB transfer, an OOM, and a crash at the
/// worst possible moment. Flushing every 2 MB keeps at most a couple of
/// megabytes in flight, because `flush()` does not return until the OS has taken
/// them.
const int kFileFlushBytes = 2 * 1024 * 1024;

/// How long a `file_offer` waits for `file_accept` or `file_reject`.
///
/// Generous on purpose: the answer is a *person* deciding whether to accept a
/// file, and the receiving UI asks them. A timeout short enough to feel snappy
/// would be one that gives up while the dialog is still on screen. A minute is
/// long enough for someone to read the file name, and short enough that a
/// transfer to a device that has quietly gone away fails while the user still
/// remembers starting it.
const Duration kOfferTimeout = Duration(seconds: 60);

/// How long a sender waits for the receiver's `file_done` after the last byte.
///
/// The receipt is the only thing that says the file was renamed into place
/// rather than merely written to a socket, so it is worth waiting for — and the
/// bytes are already sent, so what is being waited on is one frame on a
/// connection that is already up.
const Duration kTransferReceiptTimeout = Duration(seconds: 30);

/// How much file data to move between writes of the `transfer` row.
///
/// Separate from [kFileFlushBytes] although both are 2 MB, because they bound
/// different things: that one keeps the socket's buffer small, this one keeps
/// the database quiet. A 1 GB file is 4096 chunks, and a row written per chunk
/// would be four thousand transactions for a progress bar nobody reads that
/// often.
const int kTransferPersistBytes = 2 * 1024 * 1024;

/// Announce datagrams must stay under the smallest common MTU to avoid IP
/// fragmentation, which some APs handle badly. A device name + avatar that
/// overflows this is rejected rather than fragmented.
const int kMaxAnnounceBytes = 1400;

// --- Message delivery (design.md §4.5) -------------------------------------

const Duration kMsgAckTimeout = Duration(seconds: 10);
const int kMsgMaxRetries = 3;

/// Size of the recent-msgId LRU used to drop duplicates. Large enough to cover
/// any realistic re-delivery window after a reconnect.
const int kMsgDedupeWindow = 1000;

/// Longest accepted message body, in UTF-16 code units.
///
/// A storage guard rather than a product limit: `text` travels inside the frame
/// header, so without a bound a single peer could push a megabyte into the
/// local database per message. ~64k characters is far more than anyone types,
/// and still generous enough to paste a log into.
const int kMaxMessageTextLength = 64 * 1024;

/// How far a frame's `ts` may be from the local clock before it is treated as
/// broken rather than informative.
///
/// Same reasoning as [kAnnounceMaxClockSkew]; the much wider window reflects
/// that a frame's `ts` is display-only and is never used for ordering (§4.5),
/// so there is no reason to be strict about it.
const Duration kFrameMaxClockSkew = Duration(days: 3650);

// --- Shutdown ---------------------------------------------------------------

/// How long the goodbye gets on the way out — design.md §7.2.
///
/// Quitting ends the process from C++, which gives Dart no further turn: no
/// `onDispose`, no service teardown, and therefore no `bye`. So the goodbye is
/// sent explicitly first, and this is the ceiling on the whole exchange rather
/// than its expected duration — [kCloseFlushTimeout] and the socket timeouts
/// inside `DiscoveryService.stop()` are all shorter and all nested within it.
///
/// Short because it sits on the close path, where a visible pause reads as a
/// hang. Exceeding it is survivable: the peers fall back to
/// [kPeerRemoveAfter], which is the behaviour before this feature existed.
const Duration kShutdownGracePeriod = Duration(milliseconds: 500);

// --- Build metadata ---------------------------------------------------------

/// Shown on the About screen.
///
/// Hand-maintained: keep in sync with `version:` in pubspec.yaml. Reading it at
/// runtime would mean pulling in package_info_plus, which is not worth a
/// dependency just for an About row.
const String kAppVersion = '1.0.15';
