import 'dart:io';

/// Network interface enumeration and filtering — design.md §4.1.
///
/// Pure Dart (no Flutter import) so it is unit-testable without a device.
///
/// Why this exists: on Windows dev and office machines, Hyper-V / WSL2 /
/// VMware / VirtualBox / Docker each install a virtual adapter. Sending a
/// broadcast without filtering can put it on one of those instead of the real
/// Wi-Fi or Ethernet NIC, and the symptom is the worst kind — everything looks
/// correct but no peer is ever discovered. So we enumerate every interface and
/// explicitly exclude the virtual ones rather than trusting the default route.
abstract final class NetworkInterfaceHelper {
  /// Substrings that identify a virtual or otherwise unusable adapter.
  /// Matched case-insensitively against the interface name.
  /// Matched case-insensitively against the interface name.
  ///
  /// `tun` covers WireGuard's and most VPN clients' "... Tunnel" adapters.
  /// The list is necessarily a heuristic — there is no OS flag that means
  /// "this adapter is not the LAN" — so an unrecognised VPN can still slip
  /// through. That is why [primaryIpv4] also prefers LAN-shaped ranges, and why
  /// design.md §4.1 puts a manual interface picker in settings as the escape
  /// hatch. `cloudflare` is here because Cloudflare WARP's adapter was observed
  /// on a real machine being chosen over the live Wi-Fi NIC.
  static const List<String> virtualAdapterMarkers = <String>[
    'vethernet', // Hyper-V, WSL2
    'hyper-v',
    'vmware',
    'virtualbox',
    'vbox',
    'docker',
    'loopback',
    'tap-', // OpenVPN on Windows
    'tun',
    'zerotier',
    'tailscale',
    'hamachi',
    'bluetooth',
    // VPN clients that install an adapter of their own.
    'cloudflare', // WARP
    'wireguard',
    'nordlynx',
    'mullvad',
    'proton',
    'windscribe',
    'surfshark',
    'openvpn',
    'anyconnect', // Cisco
    'globalprotect', // Palo Alto
    'forticlient',
    'softether',
    'radmin',
    'teredo', // IPv6 transition tunnels
    'isatap',
    '6to4',
  ];

  /// True if the adapter is virtual or otherwise a poor choice for LAN
  /// discovery traffic.
  ///
  /// Loopback is not checked here: `NetworkInterface` exposes no such flag, and
  /// it does not need one — the loopback interface only carries 127/8
  /// addresses, which [isUsableIpv4] already rejects, so it drops out when its
  /// addresses are filtered.
  static bool isVirtual(NetworkInterface ni) {
    final String name = ni.name.toLowerCase();
    if (name == 'lo') {
      // Linux/Android loopback is named "lo", which no marker below matches.
      return true;
    }
    return virtualAdapterMarkers.any(name.contains);
  }

  /// True if [address] is usable as a LAN address.
  ///
  /// Rejects loopback (127/8) and link-local (169.254/16) — the latter means
  /// DHCP never completed, so there is no network to discover peers on.
  static bool isUsableIpv4(String address) {
    final InternetAddress addr;
    try {
      addr = InternetAddress(address);
    } on ArgumentError {
      return false;
    }
    if (addr.type != InternetAddressType.IPv4) {
      return false;
    }
    if (addr.isLoopback) {
      return false;
    }
    final List<int> bytes = addr.rawAddress;
    // 169.254.0.0/16
    if (bytes[0] == 169 && bytes[1] == 254) {
      return false;
    }
    return true;
  }

  /// All non-virtual IPv4 interfaces, each paired with its usable addresses.
  ///
  /// Interfaces with no usable address are dropped — announcing on them would
  /// be pointless.
  static Future<Map<NetworkInterface, List<String>>> usableInterfaces() async {
    final List<NetworkInterface> all;
    try {
      all = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
    } on SocketException {
      // Can happen transiently while the OS is reconfiguring adapters.
      return <NetworkInterface, List<String>>{};
    }

    final Map<NetworkInterface, List<String>> result =
        <NetworkInterface, List<String>>{};
    for (final NetworkInterface ni in all) {
      if (isVirtual(ni)) {
        continue;
      }
      final List<String> addresses = ni.addresses
          .map((InternetAddress a) => a.address)
          .where(isUsableIpv4)
          .toList(growable: false);
      if (addresses.isNotEmpty) {
        result[ni] = addresses;
      }
    }
    return result;
  }

  /// Best guess at the machine's LAN address, for display on the device card
  /// and for the address peers are told to reach us at.
  ///
  /// Returns null when no usable interface exists (e.g. airplane mode).
  ///
  /// Picks the lowest [addressRank], which both prefers private ranges over
  /// public ones and orders the private ranges by how likely they are to be the
  /// real LAN. The ordering is a heuristic, not a rule: 172.16/12 is where
  /// Docker, WARP and a long list of VPN clients squat, so it loses to 10/8 even
  /// though both are equally "private". Getting this wrong is not a cosmetic
  /// problem — the address shown here is the one advertised to peers, and a
  /// peer that is handed an unreachable address cannot connect at all.
  static Future<String?> primaryIpv4() async {
    final Map<NetworkInterface, List<String>> interfaces =
        await usableInterfaces();

    String? best;
    int bestRank = publicRank + 1; // beats nothing, so any address wins
    for (final List<String> addresses in interfaces.values) {
      for (final String address in addresses) {
        final int rank = addressRank(address);
        if (rank < bestRank) {
          best = address;
          bestRank = rank;
        }
      }
    }
    return best;
  }

  /// True if a TCP connection from [address] should be accepted.
  ///
  /// The symmetry with [isUsableIpv4] is deliberate but not identical, because
  /// the two questions are different. Discovery asks "can I reach peers from
  /// this address?" and so rejects link-local, which means DHCP never finished.
  /// Accepting asks "did this connection come from the LAN?" and link-local
  /// *is* the LAN — two devices with no DHCP server can still reach each other,
  /// and refusing them would be wrong.
  ///
  /// The rule is simply: refuse anything that arrived from the internet. The
  /// listener binds `anyIPv4`, so a router port-forward would otherwise expose
  /// it to the whole world, and this is the check that keeps a LAN-only product
  /// LAN-only. CGNAT (100.64/10) is allowed because Tailscale and carrier-grade
  /// NAT live there, and a peer reachable at such an address is a peer, not a
  /// stranger.
  static bool isAcceptablePeerAddress(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) {
      return false;
    }
    if (address.isLoopback) {
      return true; // same machine, which tests rely on
    }
    final List<int> b = address.rawAddress;
    if (b[0] == 10) return true;
    if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true; // CGNAT
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    if (b[0] == 169 && b[1] == 254) return true; // link-local
    return false;
  }

  /// Public addresses are ranked last but still usable: a machine on a routable
  /// network has no private address to prefer, and returning null would leave
  /// the device card claiming it has no address at all.
  static const int publicRank = 4;

  /// Lower is a better guess at the LAN address. Ties keep the first seen.
  static int addressRank(String address) {
    final List<int> b = InternetAddress(address).rawAddress;
    if (b[0] == 192 && b[1] == 168) {
      return 0; // home and small-office Wi-Fi
    }
    if (b[0] == 10) {
      return 1;
    }
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) {
      return 2; // also Docker, WARP and VPNs — hence third
    }
    return publicRank;
  }
}
