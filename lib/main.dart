import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/database.dart';
import 'platform/app_paths.dart';
import 'platform/wifi_lock.dart';
import 'state/data_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Taken before anything can announce, and never released until the process
  // ends. On Android the permission alone is not enough: without the lock the
  // Wi-Fi firmware drops every multicast frame and discovery finds nothing,
  // silently (see [WifiLock]). A no-op on every other platform.
  await WifiLock.acquire(
    onLog: (String message) => debugPrint('[discovery] $message'),
  );

  // Opened here rather than inside a provider because a platform path can only
  // be resolved asynchronously, and a synchronous provider is what lets every
  // widget that needs the history read it with `ref.watch` during a build.
  // Drift does not touch the file until the first query, so this costs a
  // directory lookup at startup, not a database open.
  final AppDatabase database = AppDatabase.file(await AppPaths.databaseFile());

  runApp(
    ProviderScope(
      overrides: <Override>[databaseProvider.overrideWithValue(database)],
      child: const FeijianApp(),
    ),
  );
}
