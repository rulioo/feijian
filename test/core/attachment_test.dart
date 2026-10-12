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

  // The gallery rule is a *different* question from the one above it, and these
  // are the tests that say so. The two agree on most files, which is exactly why
  // the places they disagree need pinning down.
  group('a picture belongs in the gallery even when this app cannot draw it',
      () {
    test('heic does, though isImage says no to the same file', () {
      // The whole reason this rule exists. An iPhone's photo is not something
      // the chat can render — so it shows a file card, correctly — but the
      // phone's own gallery displays it perfectly, and refusing to publish it
      // would drop the pictures most likely to be sent.
      final Attachment heic =
          attachment(fileName: 'IMG_0421.HEIC', mime: 'image/heic');
      expect(heic.isGalleryImage, isTrue);
      expect(heic.isImage, isFalse);
    });

    test('heif and avif do too', () {
      expect(attachment(fileName: 'IMG_0421.heif').isGalleryImage, isTrue);
      expect(attachment(fileName: 'IMG_0421.avif').isGalleryImage, isTrue);
    });

    test('everything this app can draw is in the gallery as well', () {
      // The list is a superset by construction, and this is what says so: a
      // format added to one and forgotten in the other would be a picture that
      // renders in the chat but never reaches the album.
      for (final String format in Attachment.extensions) {
        expect(
          attachment(fileName: 'photo.$format').isGalleryImage,
          isTrue,
          reason: '.$format draws in the chat and must therefore be published',
        );
      }
    });
  });

  group('and a picture of something that is not a photo does not', () {
    test('svg is out, though its mime type is image/', () {
      // A drawing, and a vector one — an album full of icons is the complaint
      // that gets a feature like this switched off.
      expect(
        attachment(fileName: 'logo.svg', mime: 'image/svg+xml').isGalleryImage,
        isFalse,
      );
    });

    test('tiff is out, with svg', () {
      expect(
          attachment(fileName: 'scan.tiff', mime: 'image/tiff').isGalleryImage,
          isFalse);
    });

    test('a document is not a photo', () {
      expect(attachment(fileName: 'notes.txt', mime: 'text/plain').isGalleryImage,
          isFalse);
      expect(
          attachment(fileName: 'report.pdf', mime: 'application/pdf')
              .isGalleryImage,
          isFalse);
    });

    test('a name with no type at all is not one', () {
      expect(attachment(fileName: '.png').isGalleryImage, isFalse);
      expect(attachment(fileName: 'holiday.png.').isGalleryImage, isFalse);
      expect(attachment(fileName: 'backup.png.zip').isGalleryImage, isFalse);
    });
  });

  group('the mime type the gallery is given is a concrete one', () {
    test('the extension supplies it when the sender claimed nothing useful',
        () {
      // The common case: a sender that says `application/octet-stream` for
      // everything it sends. MediaStore files the row by this column, so an
      // `image/*` or a null here would leave the picture in Files, not Photos.
      expect(
        attachment(fileName: 'photo.jpg', mime: 'application/octet-stream')
            .galleryMime,
        'image/jpeg',
      );
      expect(attachment(fileName: 'photo.jpg').galleryMime, 'image/jpeg');
      expect(attachment(fileName: 'IMG_0421.HEIC').galleryMime, 'image/heic');
    });

    test('a declared type is believed and normalised', () {
      expect(attachment(fileName: 'x', mime: 'IMAGE/PNG').galleryMime,
          'image/png');
      // Parameters are cut: the column wants a type, not a type and its
      // arguments.
      expect(
        attachment(fileName: 'x.jpg', mime: 'image/jpeg; charset=binary')
            .galleryMime,
        'image/jpeg',
      );
    });

    test('jpeg is one format under two extensions', () {
      expect(attachment(fileName: 'a.jpeg').galleryMime, 'image/jpeg');
      expect(attachment(fileName: 'b.jpg').galleryMime, 'image/jpeg');
    });

    test('the case of the extension does not reach the answer', () {
      expect(attachment(fileName: 'IMG_0421.JPG').galleryMime, 'image/jpeg');
      expect(attachment(fileName: 'shot.WebP').galleryMime, 'image/webp');
    });

    test('there is none for a file that is not going to the gallery', () {
      // Null is the caller's signal not to publish at all, so it has to be null
      // for exactly the files the rule above rejects.
      expect(attachment(fileName: 'notes.txt').galleryMime, isNull);
      expect(attachment(fileName: 'logo.svg', mime: 'image/svg+xml').galleryMime,
          isNull);
      expect(attachment(fileName: 'scan.tiff', mime: 'image/tiff').galleryMime,
          isNull);
      expect(attachment(fileName: 'noextension').galleryMime, isNull);
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
