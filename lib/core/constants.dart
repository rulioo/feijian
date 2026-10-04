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

/// No packet for this long → grey the peer out but keep the conversation readable.
const Duration kPeerOfflineAfter = Duration(seconds: 15);

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

// --- Build metadata ---------------------------------------------------------

/// Shown on the About screen.
///
/// Hand-maintained: keep in sync with `version:` in pubspec.yaml. Reading it at
/// runtime would mean pulling in package_info_plus, which is not worth a
/// dependency just for an About row.
const String kAppVersion = '1.0.0';
