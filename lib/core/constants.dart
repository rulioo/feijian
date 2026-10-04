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

// --- Connection timing ------------------------------------------------------

const Duration kHeartbeatInterval = Duration(seconds: 30);

/// Exponential backoff for reconnect attempts, in seconds.
const List<int> kReconnectBackoff = <int>[1, 2, 5, 10, 30];

/// How long to wait for an incoming `hello` before dropping a fresh socket.
/// Without this, anyone on the LAN can hold connections open by connecting
/// and staying silent.
const Duration kHandshakeTimeout = Duration(seconds: 10);

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

// --- Build metadata ---------------------------------------------------------

/// Shown on the About screen.
///
/// Hand-maintained: keep in sync with `version:` in pubspec.yaml. Reading it at
/// runtime would mean pulling in package_info_plus, which is not worth a
/// dependency just for an About row.
const String kAppVersion = '1.0.0';
