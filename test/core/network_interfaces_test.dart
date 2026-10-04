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
