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

  /// Best guess at the machine's LAN address, for display on the device card.
  ///
  /// Prefers a private-range address (192.168 / 10. / 172.16-31) since those
  /// are what peers on the same LAN will actually be reachable at.
  /// Returns null when no usable interface exists (e.g. airplane mode).
  static Future<String?> primaryIpv4() async {
    final Map<NetworkInterface, List<String>> interfaces =
        await usableInterfaces();
    String? fallback;
    for (final List<String> addresses in interfaces.values) {
      for (final String address in addresses) {
        fallback ??= address;
        if (_isPrivateIpv4(address)) {
          return address;
        }
      }
    }
    return fallback;
  }

  static bool _isPrivateIpv4(String address) {
    final List<int> b = InternetAddress(address).rawAddress;
    if (b[0] == 10) {
      return true;
    }
    if (b[0] == 192 && b[1] == 168) {
      return true;
    }
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) {
      return true;
    }
    return false;
  }
}
