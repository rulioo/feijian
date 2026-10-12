import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/download_path.dart';
import '../platform/gallery_saver.dart';
import 'data_providers.dart';
import 'lan_provider.dart';
import 'lan_service.dart';
import 'transfer_service.dart';

/// The file transfer engine — design.md §4.6.
///
/// Built on top of [lanServiceProvider] rather than beside it, because the
/// handshake travels on the control connection that service owns and the bytes
/// travel on a data connection the same manager hands out (§4.4.2). A transfer
/// layer holding its own manager would be a second listener on the same port
/// and a second set of `hello` exchanges.
///
/// Asynchronous for the same reason [lanServiceProvider] is: there is nothing to
/// construct until the control connection exists, and binding the port can fail.
/// A consumer that only wants to render something reads [transferServiceProvider]
/// through `valueOrNull` and shows nothing rather than waiting.
///
/// Watching the service rather than reading it once is what makes a rebuild of
/// [lanServiceProvider] — a port change, a rename that alters the hello — take
/// the transfer engine down with the sockets it was sending through. A
/// [TransferService] whose manager has been disposed can only fail every
/// transfer it is offered, and it subscribes to that manager's streams in its
/// own constructor, so a survivor would be a second set of listeners on the new
/// manager's frames.
final FutureProvider<TransferService> transferServiceProvider =
    FutureProvider<TransferService>((Ref ref) async {
  final LanService lan = await ref.watch(lanServiceProvider.future);

  final TransferService service = TransferService(
    manager: lan.manager,
    transfers: ref.watch(transferRepositoryProvider),
    // Resolved on each receive rather than once, because the folder the
    // platform reports can change while the app runs — a user who plugs in a
    // card and moves the default has it take effect on the next file.
    downloadDirectory: DownloadPath.resolve,
    // A received picture also goes into the system gallery, so it is somewhere
    // the user can actually reach it from — §7.1. A no-op answering false on
    // every platform but Android, which is not an error to be reported.
    publishImage: ({
      required String path,
      required String name,
      required String? mime,
    }) =>
        GallerySaver.save(
      path: path,
      name: name,
      mime: mime,
      onLog: (String message) => debugPrint('[gallery] $message'),
    ),
    onLog: (String message) => debugPrint('[xfer] $message'),
  );

  ref.onDispose(() => unawaited(service.dispose()));

  // Marks rows a previous run left saying `transferring` as failed, so a
  // progress bar does not sit at 40% forever over a socket that died with
  // the process. Awaited, so a caller that has the service also has a swept
  // database — otherwise the chat could read a stale `transferring` row and
  // render it as live.
  await service.start();
  return service;
});
