import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';
import 'package:image/image.dart' as img;
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/data/document_entity.dart';
import 'package:podofo_one/src/data/document_history_entity.dart';
import 'package:podofo_one/src/data/thumbnail_entity.dart';
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/tab_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/workers/thumbnail_worker.dart';

import 'fixtures/legacy_objectbox.g.dart' as legacy;
import 'fixtures/pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('podofo-native-tests-');
    await pdfrxInitialize(tmpPath: temporary.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temporary.delete(recursive: true);
  });

  test(
    'thumbnail cache separates display resolutions and bounds large renders',
    () async {
      final file = File('${temporary.path}/thumbnails.pdf');
      await file.writeAsBytes(pdfFixture());
      final session = await PdfSession.open(file.path);
      final container = ProviderContainer();
      try {
        Future<img.Image> render(int width, int height) async {
          final provider = thumbnailProvider((
            session: session,
            revision: session.revision,
            page: 1,
            pixelWidth: width,
            pixelHeight: height,
          ));
          final subscription = container.listen(provider, (_, _) {});
          try {
            return img.decodeJpg((await container.read(provider.future))!)!;
          } finally {
            subscription.close();
          }
        }

        final normal = await render(256, 384);
        final highDensity = await render(512, 768);
        expect(highDensity.width, greaterThan(normal.width));
        expect(highDensity.height, greaterThan(normal.height));
        expect(container.read(thumbnailCacheProvider).length, 2);
        final oversized = await render(8192, 8192);
        expect(oversized.width, lessThanOrEqualTo(1024));
        expect(oversized.height, lessThanOrEqualTo(1536));
        expect(
          container.read(thumbnailCacheProvider).bytes,
          lessThanOrEqualTo(8 * 1024 * 1024),
        );
      } finally {
        container.dispose();
        await session.close();
      }
    },
  );

  test('legacy ObjectBox data survives the auto-save rename', () {
    final path = '${temporary.path}/migration';
    var store = Store(legacy.getObjectBoxModel(), directory: path);
    final preferences = UserState()
      ..autoSaveEnabled = false
      ..highlightColor = '#66aabbcc'
      ..highlightColorPalette = ['#66aabbcc'];
    store.box<UserState>().put(preferences);
    store.box<DocumentEntity>().put(
      DocumentEntity(filePath: 'legacy.pdf', lastOpenedPage: 23),
    );
    final date = DateTime(2025, 7, 13);
    store.box<DocumentHistoryEntity>().put(
      DocumentHistoryEntity(filePath: 'legacy.pdf', lastOpened: date),
    );
    store.box<ThumbnailEntity>().put(
      ThumbnailEntity(
        filePath: 'legacy.pdf',
        pageNumber: 1,
        thumbnailData: Uint8List.fromList([1, 2, 3]),
      ),
    );
    store.close();
    store = Store(getObjectBoxModel(), directory: path);
    try {
      final current = store.box<UserState>().get(preferences.id)!;
      expect(current.autoSaveEnabled, false);
      expect(current.developerMode, false);
      expect(current.highlightColor, '#66aabbcc');
      expect(current.highlightColorPalette, ['#66aabbcc']);
      expect(store.box<DocumentEntity>().getAll().single.lastOpenedPage, 23);
      expect(
        store.box<DocumentHistoryEntity>().getAll().single.lastOpened,
        date,
      );
      expect(store.box<ThumbnailEntity>().getAll().single.thumbnailData, [
        1,
        2,
        3,
      ]);
      current.autoSaveEnabled = true;
      current.developerMode = true;
      expect(UserState.from(current).developerMode, true);
      store.box<UserState>().put(current);
    } finally {
      store.close();
    }
    store = Store(getObjectBoxModel(), directory: path);
    expect(store.box<UserState>().get(preferences.id)!.autoSaveEnabled, true);
    expect(store.box<UserState>().get(preferences.id)!.developerMode, true);
    store.close();
  });

  test('missing and corrupt PDFs do not prevent restore; retry and close normalize tabs', () async {
    final valid = File('${temporary.path}/valid.pdf')
      ..writeAsBytesSync(pdfFixture());
    final missing = File('${temporary.path}/missing.pdf');
    final corrupt = File('${temporary.path}/corrupt.pdf')
      ..writeAsStringSync('not a pdf');
    final store = Store(
      getObjectBoxModel(),
      directory: '${temporary.path}/restore-db',
    );
    store.box<DocumentEntity>().putMany([
      DocumentEntity(filePath: missing.path),
      DocumentEntity(filePath: valid.path, lastOpenedPage: 999),
      DocumentEntity(filePath: corrupt.path),
    ]);
    final container = ProviderContainer(
      overrides: [objectboxProvider.overrideWithValue(ObjectBox(store))],
    );
    try {
      final restored = await container.read(initialDocumentsProvider.future);
      expect(restored.length, 1);
      expect(restored.values.single.lastOpenedPage, 3);
      expect(container.read(documentFailuresProvider).length, 2);
      await missing.writeAsBytes(pdfFixture());
      final notifier = container.read(loadedDocumentsProvider.notifier);
      expect(await notifier.addDocument(missing.path), true);
      expect(container.read(loadedDocumentsProvider).length, 2);
      await notifier.addDocument(missing.path);
      expect(container.read(loadedDocumentsProvider).length, 2);
      await notifier.removeDocument(
        container.read(currentDocumentProvider)!.filePath,
      );
      expect(container.read(currentTabIndexProvider), 0);
      expect(container.read(currentDocumentProvider), isNotNull);
      notifier.forgetUnavailable(corrupt.path);
      expect(container.read(documentFailuresProvider), isEmpty);
    } finally {
      container.dispose();
      store.close();
    }
  });

  test('highlights persist on cropped and rotated pages, undo persists, and edits protect close', () async {
    final file = File('${temporary.path}/highlights.pdf')
      ..writeAsBytesSync(pdfFixture());
    final session = await PdfSession.open(file.path);
    final regions = <HighlightRegion>[];
    for (final page in session.lease.document.pages) {
      final text = await page.loadStructuredText();
      final match = await text.allMatches('Hello').first;
      regions.add(
        HighlightRegion(
          page.pageNumber,
          match.enumerateFragmentBoundingRects().map((f) => f.bounds).toList(),
          text: match.text,
        ),
      );
    }
    await session.highlight(regions, 0x88ffeb3b);
    expect(session.dirty, true);
    await expectLater(session.close(), throwsStateError);
    await session.save();
    expect(session.dirty, false);
    final reopened = await PdfDocument.openFile(file.path);
    try {
      await reopened.useNativeDocumentHandle((handle) {
        final api = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
        final native = Pointer<fpdf_document_t__>.fromAddress(handle);
        for (var index = 0; index < 3; index++) {
          final page = api.FPDF_LoadPage(native, index);
          try {
            expect(api.FPDFPage_GetAnnotCount(page), 1);
            final annotation = api.FPDFPage_GetAnnot(page, 0);
            try {
              expect(
                api.FPDFAnnot_GetSubtype(annotation),
                FPDF_ANNOT_HIGHLIGHT,
              );
              using((arena) {
                final quad = arena<FS_QUADPOINTSF>();
                final box = arena<FS_RECTF>();
                expect(api.FPDF_GetPageBoundingBox(page, box), 1);
                expect(
                  api.FPDFAnnot_GetAttachmentPoints(annotation, 0, quad),
                  1,
                );
                expect(
                  quad.ref.x1,
                  closeTo(
                    regions[index].rects.first.left + box.ref.left,
                    0.001,
                  ),
                );
                expect(
                  quad.ref.y1,
                  closeTo(
                    regions[index].rects.first.top + box.ref.bottom,
                    0.001,
                  ),
                );
              });
            } finally {
              api.FPDFPage_CloseAnnot(annotation);
            }
          } finally {
            api.FPDF_ClosePage(page);
          }
        }
      });
      final render = await reopened.pages.first.render(
        fullWidth: 260,
        fullHeight: 360,
      );
      expect(render, isNotNull);
      final pixels = img.Image.fromBytes(
        width: render!.width,
        height: render.height,
        bytes: render.pixels.buffer,
        order: img.ChannelOrder.bgra,
      );
      expect(
        pixels
            .where((pixel) => pixel.r > 180 && pixel.g > 150 && pixel.b < 220)
            .length,
        greaterThan(50),
      );
      Directory('build/test-artifacts').createSync(recursive: true);
      File('build/test-artifacts/annotated-cropped.png')
          .writeAsBytesSync(img.encodePng(pixels));
      render.dispose();
    } finally {
      await reopened.dispose();
    }
    await session.undoHighlight();
    await session.save();
    await session.close();
    final undone = await PdfDocument.openFile(file.path);
    await undone.useNativeDocumentHandle((handle) {
      final api = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
      final page = api.FPDF_LoadPage(
        Pointer<fpdf_document_t__>.fromAddress(handle),
        0,
      );
      expect(api.FPDFPage_GetAnnotCount(page), 0);
      api.FPDF_ClosePage(page);
    });
    await undone.dispose();
  });

  test('save conflicts preserve both external bytes and dirty edits; Save As recovers', () async {
    final file = File('${temporary.path}/conflict.pdf')
      ..writeAsBytesSync(pdfFixture());
    final session = await PdfSession.open(file.path);
    await session.highlight([
      const HighlightRegion(1, [PdfRect(30, 280, 90, 260)]),
    ], 0x88ffff00);
    final external = Uint8List.fromList([...pdfFixture(), 10, 37, 32, 120]);
    await file.writeAsBytes(external);
    await expectLater(session.save(), throwsStateError);
    expect(await file.readAsBytes(), external);
    expect(session.dirty, true);
    final copy = '${temporary.path}/copy.pdf';
    await session.save(destination: copy);
    expect(session.path, copy.replaceAll('/', Platform.pathSeparator));
    expect(session.dirty, false);
    expect(await file.readAsBytes(), external);
    await session.close();
  });

  test('failed writes do not overwrite an existing destination', () async {
    final target = File('${temporary.path}/protected.pdf')
      ..writeAsBytesSync(pdfFixture());
    final original = await target.readAsBytes();
    await expectLater(
      AtomicPdfFile.write(
        target.path,
        Uint8List.fromList([1, 2, 3]),
        expectedFingerprint: null,
      ),
      throwsStateError,
    );
    expect(await target.readAsBytes(), original);
  });

  test('saving an unchanged PDF as a copy preserves its exact bytes', () async {
    final original = pdfFixture();
    final file = File('${temporary.path}/unchanged.pdf')
      ..writeAsBytesSync(original);
    final session = await PdfSession.open(file.path);
    final copy = File('${temporary.path}/unchanged-copy.pdf');
    await session.save(destination: copy.path);
    expect(await copy.readAsBytes(), original);
    await session.close();
  });

  test('existing highlights can be removed after reopening without stale-index deletion', () async {
    final file = File('${temporary.path}/remove.pdf')
      ..writeAsBytesSync(pdfFixture());
    var session = await PdfSession.open(file.path);
    await session.highlight([
      const HighlightRegion(1, [PdfRect(30, 280, 90, 260)], text: 'Saved note'),
    ], 0x88ffff00);
    await session.save();
    await session.close();
    session = await PdfSession.open(file.path);
    final items = await session.lease.use(
      (pdf) => PdfHighlights.listPage(pdf, 1),
    );
    // Selected text is geometry input, not an annotation comment.
    expect(items.single.text, isEmpty);
    await expectLater(
      session.removeHighlight(items.single, 99),
      throwsStateError,
    );
    await session.removeHighlight(items.single, session.revision);
    expect(session.dirty, true);
    await session.save();
    await session.close();
    final check = await PdfSession.open(file.path);
    expect(
      await check.lease.use((pdf) => PdfHighlights.listPage(pdf, 1)),
      isEmpty,
    );
    await check.close();
  });

  test('auto-save writes edits, reports conflicts, and Save As updates session records', () async {
    final file = File('${temporary.path}/auto.pdf')
      ..writeAsBytesSync(pdfFixture());
    final store = Store(
      getObjectBoxModel(),
      directory: '${temporary.path}/auto-db',
    );
    final container = ProviderContainer(
      overrides: [objectboxProvider.overrideWithValue(ObjectBox(store))],
    );
    try {
      final notifier = container.read(loadedDocumentsProvider.notifier);
      await notifier.addDocument(file.path);
      final document = container.read(currentDocumentProvider)!;
      await notifier.highlight(document, [
        const HighlightRegion(1, [PdfRect(30, 280, 90, 260)]),
      ], 0x88ffff00);
      expect(document.dirty, false);
      final saved = await PdfSession.open(file.path);
      expect(
        await saved.lease.use((pdf) => PdfHighlights.listPage(pdf, 1)),
        hasLength(1),
      );
      await saved.close();
      final external = pdfFixture();
      await file.writeAsBytes(external);
      await notifier.undoHighlight(document);
      expect(document.dirty, true);
      expect(
        container.read(documentErrorProvider),
        contains('Auto-save failed'),
      );
      expect(await file.readAsBytes(), external);
      await notifier.saveDocument(
        document,
        destination: '${temporary.path}/recovered.pdf',
      );
      expect(document.dirty, false);
      expect(
        store.box<DocumentEntity>().getAll().single.filePath,
        document.filePath,
      );
      expect(
        container.read(loadedDocumentsProvider).keys.single,
        document.filePath,
      );
    } finally {
      container.dispose();
      store.close();
    }
  });
}
