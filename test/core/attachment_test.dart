import 'package:feijian/core/models/transfer.dart';
import 'package:flutter_test/flutter_test.dart';

/// What an attachment says about itself — design.md §5.1, §6.3.
void main() {
  Attachment attachment({
    String fileName = 'file',
    String? mime,
    int size = 1024,
    int transferred = 0,
    TransferState state = TransferState.done,
  }) {
    return Attachment(
      id: 'att-1',
      messageId: 'msg-1',
      fileName: fileName,
      size: size,
      mime: mime,
      state: state,
      transferred: transferred,
    );
  }

  group('a picture is one this app can actually draw', () {
    test('a .png is one', () {
      expect(attachment(fileName: 'holiday.png').isImage, isTrue);
    });

    test('the extension is read whatever its case', () {
      // A name typed on Windows or off a camera roll arrives in either case,
      // and `.JPG` is the same format as `.jpg`.
      expect(attachment(fileName: 'IMG_0421.JPG').isImage, isTrue);
      expect(attachment(fileName: 'shot.WebP').isImage, isTrue);
    });

    test('a mime type is enough on its own, for a name with no extension', () {
      // A phone that sends a screenshot sometimes sends no name at all — and
      // the mime type is then the only thing that says what it is.
      expect(
          attachment(fileName: 'IMG_0421', mime: 'image/png').isImage, isTrue);
    });

    test('a mime type in the wrong case still counts', () {
      expect(attachment(fileName: 'x', mime: 'IMAGE/PNG').isImage, isTrue);
    });

    test('the name is the fallback when the mime type says nothing', () {
      // `application/octet-stream` is what a great many senders claim for
      // everything, so a `.jpg` behind one is still a picture.
      expect(
        attachment(fileName: 'photo.jpg', mime: 'application/octet-stream')
            .isImage,
        isTrue,
      );
    });
  });

  group('a format this app cannot decode is not drawn as one', () {
    test('svg is not, though its mime type says image/', () {
      // The mime type is a real `image/`, and `Image.file` still cannot draw
      // it without a package this app does not ship. Saying yes here would put
      // a broken-image box in the chat where a file card belongs.
      expect(
        attachment(fileName: 'logo.svg', mime: 'image/svg+xml').isImage,
        isFalse,
      );
    });

    test('heic is not, though an iPhone sends it as image/heic', () {
      expect(
        attachment(fileName: 'IMG_0421.HEIC', mime: 'image/heic').isImage,
        isFalse,
      );
    });

    test('an unknown subtype under image/ falls through to the name', () {
      // `image/tiff` is not decodable either, but the *name* may still say
      // something that is — and a name is what the receiving end actually has.
      expect(attachment(fileName: 'scan.tiff', mime: 'image/tiff').isImage,
          isFalse);
      expect(
          attachment(fileName: 'scan.png', mime: 'image/tiff').isImage, isTrue);
    });

    test('a document is not a picture', () {
      expect(attachment(fileName: 'notes.txt', mime: 'text/plain').isImage,
          isFalse);
      expect(
          attachment(fileName: 'report.pdf', mime: 'application/pdf').isImage,
          isFalse);
    });

    test('a name that is all extension is not one', () {
      // A dot at the front makes a hidden file, not a type — and `.png` as a
      // whole name is a file called `.png`, not a picture.
      expect(attachment(fileName: '.png').isImage, isFalse);
      expect(attachment(fileName: 'png').isImage, isFalse);
    });

    test('a dot at the end is not a type either', () {
      expect(attachment(fileName: 'holiday.png.').isImage, isFalse);
    });

    test('only the last component of a compound name is read', () {
      expect(attachment(fileName: 'photos.tar.gz').isImage, isFalse);
      expect(attachment(fileName: 'backup.png.zip').isImage, isFalse);
    });
  });

  group('progress is a ratio of what was agreed to', () {
    test('an unfinished transfer is how far it has got', () {
      final Attachment moving = attachment(
        size: 1000,
        transferred: 250,
        state: TransferState.transferring,
      );
      expect(moving.progress, 0.25);
    });

    test('a finished one is complete whatever the count says', () {
      // The byte count is written on a checkpoint, so a small file can finish
      // between two of them and read `done` at 0 of 900 bytes.
      final Attachment done = attachment(size: 900, transferred: 0);
      expect(done.progress, 1);
    });

    test('a zero-byte file is complete rather than stuck at zero', () {
      final Attachment empty = attachment(
        size: 0,
        state: TransferState.transferring,
      );
      expect(empty.progress, 1);
    });

    test('a count past the size does not overflow the bar', () {
      final Attachment over = attachment(
        size: 100,
        transferred: 400,
        state: TransferState.transferring,
      );
      expect(over.progress, 1);
    });
  });

  group('the bytes are openable only when they are all here', () {
    test('a finished transfer with a path is', () {
      final Attachment landed = Attachment(
        id: 'a',
        messageId: 'm',
        fileName: 'x.bin',
        size: 1,
        state: TransferState.done,
        localPath: '/tmp/x.bin',
      );
      expect(landed.isOpenable, isTrue);
    });

    test('a finished transfer with no path is not', () {
      // Possible for a row written by an older run, or by a transfer whose
      // install step failed after the state was set.
      expect(attachment().isOpenable, isFalse);
    });

    test('a cancelled transfer whose path survives is not', () {
      final Attachment stopped = Attachment(
        id: 'a',
        messageId: 'm',
        fileName: 'x.bin',
        size: 1,
        state: TransferState.cancelled,
        localPath: '/tmp/x.bin',
      );
      expect(stopped.isOpenable, isFalse);
    });
  });
}
