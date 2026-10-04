import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/database.dart';
import 'platform/app_paths.dart';
import 'state/data_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
