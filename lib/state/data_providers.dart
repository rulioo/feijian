import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository/chat_repository.dart';
import '../data/repository/peer_repository.dart';
import '../data/repository/settings_repository.dart';

/// The history database.
///
/// Deliberately has no default implementation: opening a real database needs a
/// platform path and an async call, neither of which fits inside a synchronous
/// provider, and quietly falling back to an in-memory database would produce an
/// app that works perfectly and forgets everything on restart.
///
/// [main] overrides it with `AppDatabase.file(await AppPaths.databaseFile())`
/// once at startup; tests override it with `AppDatabase.memory()`. Everything
/// downstream is then synchronous and can be read with `ref.watch` from a widget
/// build.
final Provider<AppDatabase> databaseProvider = Provider<AppDatabase>((Ref ref) {
  throw StateError(
    'databaseProvider must be overridden in main() with the real database, or '
    'in a test with AppDatabase.memory().',
  );
});

final Provider<PeerRepository> peerRepositoryProvider =
    Provider<PeerRepository>((Ref ref) {
      return PeerRepository(ref.watch(databaseProvider));
    });

final Provider<ChatRepository> chatRepositoryProvider =
    Provider<ChatRepository>((Ref ref) {
      return ChatRepository(ref.watch(databaseProvider));
    });

final Provider<SettingsRepository> settingsRepositoryProvider =
    Provider<SettingsRepository>((Ref ref) {
      return SettingsRepository(ref.watch(databaseProvider));
    });
