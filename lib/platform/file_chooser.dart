import 'dart:io';

import 'package:file_picker/file_picker.dart';

/// The file dialogs this app asks the operating system for — design.md §6.3.
///
/// An object rather than a set of statics, so a widget test can answer for a
/// dialog without one. The composer's paperclip and the drop overlay both end in
/// the same place, and the part worth testing is what the page does with an
/// answer, not whether the operating system can draw a window.
class FileChooser {
  const FileChooser();

  /// The files the user picked to send, as absolute paths.
  ///
  /// Empty for a cancelled dialog and for a dialog that came back with nothing,
  /// which are the same thing to every caller: there are no files to send either
  /// way, and a distinction nothing acts on is a distinction to leave out.
  ///
  /// Paths rather than `PlatformFile`s, because the engine wants a `File` to
  /// stream from. `withData: false` is what keeps a picked 1GB video from being
  /// read into memory on the way to being sent — which is the memory §11 asks to
  /// hold flat, spent before the transfer has even started.
  Future<List<String>> pickFiles() async {
    final FilePickerResult? result = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: false,
      // The user knows what they mean to send, and a filter here would be a
      // second guess at it — one that hides the file they are looking for with
      // no way to ask for everything.
      type: FileType.any,
    );
    if (result == null) {
      return const <String>[];
    }
    return <String>[
      // A file from a provider that offers only bytes has no path, and there is
      // nothing to stream from one. It is not a file this app can send.
      for (final PlatformFile file in result.files)
        if (file.path != null) file.path!,
    ];
  }

  /// The folder the user picked to send, or null if they cancelled.
  ///
  /// One folder rather than several: §4.6's offer describes a single tree, so a
  /// multi-select would be several offers — and a caller that wants two can ask
  /// twice.
  ///
  /// **A path the picker cannot hand over is answered as a cancelled dialog**,
  /// which is a lie the caller can act on and the alternative is not. Android's
  /// tree picker goes through the Storage Access Framework (§7.1), and a tree
  /// this app has not been granted says so by coming back as `/` — the one
  /// answer that is never a real choice there and would have the walk try to
  /// list the whole file system. On Linux `/` is somebody's actual home
  /// directory's parent, which is why the guard is not shared.
  Future<String?> pickFolder() async {
    final String? path = await FilePicker.getDirectoryPath();
    if (path == null) {
      return null;
    }
    if (Platform.isAndroid && path == '/') {
      return null;
    }
    return path;
  }

  /// Whether a file can be copied to a place the user picks.
  ///
  /// True on the three desktops, false on Android. Not a limitation of this
  /// code: [FilePicker.saveFile] on Android answers with a Storage
  /// Access Framework document, which the app can only write through a stream
  /// the plugin does not expose — what it does expose is `bytes`, and a
  /// gigabyte in one `Uint8List` on a phone is the memory the rest of this
  /// design works to avoid. Files still arrive and still open on Android; they
  /// land in the app's own folder, and moving one out is the same storage work
  /// `DownloadPath.resolve` has a TODO for.
  bool get canSaveAs =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Where to put a copy of [fileName], or null if the user cancelled.
  ///
  /// Desktop only — see [canSaveAs]. The dialog comes back with a name and
  /// writes nothing: passing `bytes` is what would make it write, and that is
  /// the one thing this cannot do for a large file. [copy] is the other half.
  Future<String?> pickSaveLocation(String fileName) async {
    if (!canSaveAs) {
      return null;
    }
    return FilePicker.saveFile(
      fileName: fileName,
      type: FileType.any,
    );
  }

  /// Copies [from] over [to], streaming, and says whether it worked.
  ///
  /// `File.copy` is a native copy that moves the file in chunks; reading it into
  /// memory first would be the same mistake as `bytes` above, and would fail
  /// outright on the files this button exists for.
  ///
  /// Overwrites without asking, because the save dialog already asked — its
  /// Windows implementation is created with `confirmOverwrite`.
  Future<bool> copy(String from, String to) async {
    try {
      await File(from).copy(to);
      return true;
    } on FileSystemException {
      // A target on a drive that went away, a name the filesystem refuses, a
      // source deleted between the save dialog and here. The caller says so and
      // nothing is left half-written — `copy` removes its own partial file.
      return false;
    }
  }
}
