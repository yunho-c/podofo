import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/workers/link_preview_worker.dart';

import 'fixtures/hover_pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native crops find the destination on offset and rotated pages',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'podofo-preview-',
      );
      await pdfrxInitialize(tmpPath: temporary.path);
      final file = File('${temporary.path}/links.pdf');
      await file.writeAsBytes(hoverPdfFixture());
      final session = await PdfSession.open(file.path);
      final worker = LinkPreviewWorker();
      try {
        final links = await session.readLocked(
          (pdf) => pdf.pages.first.loadLinks(),
        );
        expect(links.length, 7);
        const markerCenters = [
          ui.Offset(400, 280),
          ui.Offset(480, 400),
          ui.Offset(160, 480),
          ui.Offset(280, 160),
        ];
        for (var i = 0; i < 4; i++) {
          final dest = links[i].dest!;
          expect(dest.pageNumber, i + 2);
          final page = session.lease.document.pages[dest.pageNumber - 1];
          expect(page.rotation.index, i);
          final image = (await worker.load(session, dest, pixelRatio: 3))!;
          try {
            expect(image.width, lessThanOrEqualTo(720));
            expect(image.height, lessThanOrEqualTo(480));
            final region = LinkPreviewRegion.forDestination(
              page,
              dest,
              const PdfRect(30, 800, 590, 40),
              3,
            )!;
            final x = (markerCenters[i].dx * region.scale - region.x).round();
            final y = (markerCenters[i].dy * region.scale - region.y).round();
            final pixels = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final offset = (y * image.width + x) * 4;
            expect(
              pixels.getUint8(offset),
              greaterThan(240),
              reason: 'red on rotation $i',
            );
            expect(pixels.getUint8(offset + 1), lessThan(10));
            expect(pixels.getUint8(offset + 2), lessThan(10));
            await Directory('build/test-artifacts').create(recursive: true);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('build/test-artifacts/hover-rotation-${i * 90}.png')
                .writeAsBytes(png!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        }
        final whole = (await worker.load(
          session,
          links[4].dest!,
          pixelRatio: 2,
        ))!;
        expect(whole.height, 480);
        expect(whole.width / whole.height, closeTo(560 / 760, .005));
        whole.dispose();
        final figure = (await worker.load(
          session,
          links[5].dest!,
          pixelRatio: 2,
        ))!;
        expect(figure.width / figure.height, closeTo(64 / 84, .005));
        figure.dispose();
        for (final page in [0, 6]) {
          expect(
            await worker.load(
              session,
              PdfDest(page, PdfDestCommand.fit, null),
              pixelRatio: 2,
            ),
            isNull,
          );
        }
        expect(session.navigationHistory.previous, isNull);
        expect(session.revision, 0);
        expect(session.dirty, false);
      } finally {
        worker.dispose();
        await session.close();
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        await temporary.delete(recursive: true);
      }
    },
  );
}
