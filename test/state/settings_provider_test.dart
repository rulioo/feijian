import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/settings_repository.dart';
import 'package:feijian/state/data_providers.dart';
import 'package:feijian/state/settings_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The settings store, and the one failure it is built to survive.
///
/// A preference is a field, a line in `_encode` and a line in `_decode`, and
/// only the first of the three is a compile error to get wrong. A field with no
/// `_encode` line is never written, and — since `update` diffs the encoded maps
/// to decide whether anything changed — a flip of it is not even noticed; a
/// field with a `_decode` line that reads a different key comes back at its
/// default forever. Both look exactly like a working switch until the app is
/// restarted, which is what these tests do.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() async => db.close());

  ProviderContainer container() {
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[databaseProvider.overrideWithValue(db)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a store with nothing in it answers with the defaults', () async {
    final ProviderContainer c = container();
    c.read(settingsProvider);
    await pumpEventQueue();

    expect(
      c.read(settingsProvider).confirmBeforeReceiving,
      isFalse,
      reason: 'a fresh install receives without asking — the product decision',
    );
  });

  test('the receive-confirmation switch is still set after a restart', () async {
    final ProviderContainer first = container();
    first.read(settingsProvider.notifier).update(
          (AppSettings s) => s.copyWith(confirmBeforeReceiving: true),
        );
    // The write is deliberately not awaited by `update` — the UI must not wait
    // on a disk — so the rows land on the event queue after it returns.
    await pumpEventQueue();

    expect(
      await SettingsRepository(db).getString(
        SettingKeys.confirmBeforeReceiving,
      ),
      'true',
      reason: 'the row is what the next launch reads, whatever this session '
          'happens to hold',
    );

    // A second container is the next launch: same file, new notifier.
    final ProviderContainer second = container();
    second.read(settingsProvider);
    await pumpEventQueue();

    expect(second.read(settingsProvider).confirmBeforeReceiving, isTrue);
  });

  test('turning it back off is stored too', () async {
    // The other direction, because a `_bool` that only ever answered true would
    // pass the test above — `'false'` is a value, not the absence of one, and
    // the difference is a switch the user cannot turn off again.
    //
    // The row is read as well as the state, and that assertion is not
    // decoration: "off" is what a *missing* row also produces, so a switch
    // whose key was never written would come back off and pass a test that only
    // looked at the state — the exact failure this file exists for.
    final ProviderContainer first = container();
    first.read(settingsProvider.notifier).update(
          (AppSettings s) => s.copyWith(confirmBeforeReceiving: true),
        );
    await pumpEventQueue();
    first.read(settingsProvider.notifier).update(
          (AppSettings s) => s.copyWith(confirmBeforeReceiving: false),
        );
    await pumpEventQueue();

    expect(
      await SettingsRepository(db).getString(
        SettingKeys.confirmBeforeReceiving,
      ),
      'false',
      reason: 'written, and written as a value rather than deleted',
    );

    final ProviderContainer second = container();
    second.read(settingsProvider);
    await pumpEventQueue();

    expect(second.read(settingsProvider).confirmBeforeReceiving, isFalse);
  });
}
