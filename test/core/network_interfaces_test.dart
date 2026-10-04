import 'package:feijian/core/discovery/network_interfaces.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NetworkInterfaceHelper.isUsableIpv4', () {
    test('accepts ordinary LAN addresses', () {
      expect(NetworkInterfaceHelper.isUsableIpv4('192.168.1.100'), isTrue);
      expect(NetworkInterfaceHelper.isUsableIpv4('10.0.0.5'), isTrue);
      expect(NetworkInterfaceHelper.isUsableIpv4('172.16.4.9'), isTrue);
    });

    test('rejects loopback', () {
      expect(NetworkInterfaceHelper.isUsableIpv4('127.0.0.1'), isFalse);
      expect(NetworkInterfaceHelper.isUsableIpv4('127.5.5.5'), isFalse);
    });

    test('rejects link-local, where DHCP never completed', () {
      expect(NetworkInterfaceHelper.isUsableIpv4('169.254.13.7'), isFalse);
    });

    test('rejects IPv6', () {
      expect(NetworkInterfaceHelper.isUsableIpv4('fe80::1'), isFalse);
      expect(NetworkInterfaceHelper.isUsableIpv4('::1'), isFalse);
    });

    test('rejects non-addresses instead of throwing', () {
      expect(NetworkInterfaceHelper.isUsableIpv4(''), isFalse);
      expect(NetworkInterfaceHelper.isUsableIpv4('not-an-ip'), isFalse);
      expect(NetworkInterfaceHelper.isUsableIpv4('192.168.1.999'), isFalse);
    });
  });

  group('NetworkInterfaceHelper.addressRank', () {
    test('prefers the ranges a real LAN is most likely to use', () {
      expect(
        NetworkInterfaceHelper.addressRank('192.168.3.46'),
        lessThan(NetworkInterfaceHelper.addressRank('10.0.0.5')),
      );
      expect(
        NetworkInterfaceHelper.addressRank('10.0.0.5'),
        lessThan(NetworkInterfaceHelper.addressRank('172.16.0.2')),
      );
    });

    test('ranks a public address last but still usable', () {
      // Returning null here would leave the device card claiming this machine
      // has no address at all, on a network that works perfectly well.
      expect(
        NetworkInterfaceHelper.addressRank('172.16.0.2'),
        lessThan(NetworkInterfaceHelper.addressRank('203.0.113.9')),
      );
      expect(
        NetworkInterfaceHelper.addressRank('203.0.113.9'),
        NetworkInterfaceHelper.publicRank,
      );
    });

    test('does not treat every 172.x as private', () {
      // 172.32/12 is outside the private block; only 172.16-31 is.
      expect(
        NetworkInterfaceHelper.addressRank('172.32.0.1'),
        NetworkInterfaceHelper.publicRank,
      );
    });
  });

  group('NetworkInterfaceHelper.virtualAdapterMarkers', () {
    test('covers the adapters that actually break Windows discovery', () {
      const List<String> realWorldNames = <String>[
        'vEthernet (Default Switch)',
        'vEthernet (WSL (Hyper-V firewall))',
        'VMware Network Adapter VMnet1',
        'VirtualBox Host-Only Network',
        'Docker Desktop',
        // Observed on a development machine being chosen over the live Wi-Fi
        // adapter, because 172.16.0.2 looks like a private LAN address.
        'CloudflareWARP',
        'WireGuard Tunnel',
        'Tailscale',
        'ZeroTier One',
        'Bluetooth Network Connection',
      ];

      for (final String name in realWorldNames) {
        expect(
          NetworkInterfaceHelper.virtualAdapterMarkers
              .any((String marker) => name.toLowerCase().contains(marker)),
          isTrue,
          reason: '"$name" must be filtered out or discovery goes nowhere',
        );
      }
    });

    test('leaves ordinary adapter names alone', () {
      for (final String name in <String>['WLAN', 'Ethernet', 'Wi-Fi', 'en0']) {
        expect(
          NetworkInterfaceHelper.virtualAdapterMarkers
              .any((String marker) => name.toLowerCase().contains(marker)),
          isFalse,
          reason: '"$name" is a real adapter and must be kept',
        );
      }
    });
  });

  group('NetworkInterfaceHelper.primaryIpv4', () {
    test('returns a usable address or null, never a bad one', () async {
      final String? ip = await NetworkInterfaceHelper.primaryIpv4();
      // A CI box or an offline dev machine legitimately has none.
      if (ip != null) {
        expect(NetworkInterfaceHelper.isUsableIpv4(ip), isTrue);
      }
    });
  });
}
