import 'package:feijian/core/discovery/discovery_service.dart';
import 'package:feijian/state/providers.dart';
import 'package:feijian/ui/widgets/discovery_lifecycle.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// What these tests cover is the trigger, not the repair: that coming back from
/// being away calls `rescan()` and that the things which look similar but are
/// not a departure do not. What `rescan()` then does to the sockets is the
/// subject of the tests in `test/core/discovery_service_test.dart`, which drive
/// real datagrams — so this file stubs the call out rather than repeating them.
class _CountingDiscovery extends DiscoveryService {
  _CountingDiscovery() : super(discoveryPort: 0);

  int rescans = 0;

  @override
  void rescan() => rescans++;
}

void main() {
  late _CountingDiscovery service;

  Future<void> pump(
    WidgetTester tester, {
    Duration minimumAway = Duration.zero,
  }) async {
    service = _CountingDiscovery();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          discoveryServiceProvider.overrideWithValue(service),
        ],
        child: DiscoveryLifecycle(
          minimumAway: minimumAway,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  void lifecycle(WidgetTester tester, AppLifecycleState state) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }

  testWidgets('coming back from the background rescans', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    lifecycle(tester, AppLifecycleState.paused);
    lifecycle(tester, AppLifecycleState.resumed);

    expect(service.rescans, 1);
  });

  testWidgets('a minimised window is also being away', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    // A minimised desktop window stops at `hidden` and never reaches `paused`.
    lifecycle(tester, AppLifecycleState.hidden);
    lifecycle(tester, AppLifecycleState.resumed);

    expect(service.rescans, 1);
  });

  testWidgets('a cold start does not rescan a service that just started', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    // What the platform delivers on launch. Joining the multicast group is the
    // first thing discovery does, and rebuilding the sockets a moment later
    // would be work with nothing to repair.
    lifecycle(tester, AppLifecycleState.resumed);

    expect(service.rescans, 0);
  });

  testWidgets('losing focus is not being away', (WidgetTester tester) async {
    await pump(tester);

    // `inactive` is what a lost window focus and a pulled-down notification
    // shade look like too, and neither of those takes the network away.
    lifecycle(tester, AppLifecycleState.inactive);
    lifecycle(tester, AppLifecycleState.resumed);

    expect(service.rescans, 0);
  });

  testWidgets('a glance at the app switcher is not worth a rebuild', (
    WidgetTester tester,
  ) async {
    // As long as no test can take, which is the point: the threshold has to
    // have elapsed, and here it cannot. Uses a real duration rather than a
    // clock stub because the state being tested is exactly "not enough time
    // passed", and asserting that against a frozen clock would prove nothing.
    await pump(tester, minimumAway: const Duration(minutes: 5));

    lifecycle(tester, AppLifecycleState.paused);
    lifecycle(tester, AppLifecycleState.resumed);

    expect(service.rescans, 0);
  });

  testWidgets('the threshold is measured from when the app left', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    // Two departures, and only the second one resumes.
    lifecycle(tester, AppLifecycleState.paused);
    lifecycle(tester, AppLifecycleState.paused);
    lifecycle(tester, AppLifecycleState.resumed);

    expect(service.rescans, 1);
  });

  testWidgets('an unmounted observer stops rescanning', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    await tester.pumpWidget(const SizedBox.shrink());

    lifecycle(tester, AppLifecycleState.paused);
    lifecycle(tester, AppLifecycleState.resumed);

    expect(service.rescans, 0);
  });
}
