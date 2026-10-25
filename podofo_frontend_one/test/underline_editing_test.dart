import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';
import 'package:podofo_one/src/editing/annotation_edit.dart';
import 'package:podofo_one/src/editing/pdf_annotation_adapter.dart';
import 'package:podofo_one/src/editing/pdfium_document_task.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/spaced_text_pdf.dart';
import 'fixtures/pdf_fixture.dart';
import 'fixtures/annotation_pdf.dart';

const _regions = [
  HighlightRegion(1, [PdfRect(30, 100, 110, 80), PdfRect(170, 100, 230, 80)]),
];

List<({int subtype, bool appearance})> _annotations(int handle, int number) {
  final api = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
  final page = api.FPDF_LoadPage(
    Pointer<fpdf_document_t__>.fromAddress(handle),
    number - 1,
  );
  try {
    return [
      for (var i = 0; i < api.FPDFPage_GetAnnotCount(page); i++)
        (() {
          final a = api.FPDFPage_GetAnnot(page, i);
          try {
            return (
              subtype: api.FPDFAnnot_GetSubtype(a),
              appearance:
                  api.FPDFAnnot_GetAP(
                    a,
                    FPDF_ANNOT_APPEARANCEMODE_NORMAL,
                    nullptr,
                    0,
                  ) >
                  2,
            );
          } finally {
            api.FPDFPage_CloseAnnot(a);
          }
        })(),
    ];
  } finally {
    api.FPDF_ClosePage(page);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String pdfkit;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('podofo-underline-');
    await pdfrxInitialize(tmpPath: temp.path);
    if (Platform.isMacOS) {
      pdfkit = '${temp.path}/render-underline';
      final build = await Process.run('xcrun', [
        'swiftc',
        'test/support/render_underline_pdfkit.swift',
        '-o',
        pdfkit,
      ]);
      expect(build.exitCode, 0, reason: '${build.stderr}');
    }
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temp.delete(recursive: true);
  });

  for (final rotation in [0, 90, 180, 270]) {
    test(
      'red underline subtype, appearance, history and reopen at $rotation degrees',
      () async {
        final file = File('${temp.path}/underline-$rotation.pdf');
        await file.writeAsBytes(
          spacedTextPdf(cropped: true, rotation: rotation),
        );
        final s = await PdfSession.open(file.path);
        try {
          await s.underline(_regions);
          final a = (await s.annotations()).single;
          expect(a.kind, AnnotationKind.underline);
          expect(a.argb, 0xffff0000);
          expect(a.canRecolor, false);
          expect(a.canEdit, true);
          expect(a.author, isEmpty);
          expect(a.contents, isEmpty);
          expect(a.pdfName, startsWith('PoDoFo:'));
          expect(s.undoLabel, 'Add underline');
          await s.undo();
          expect(await s.annotations(), isEmpty);
          await s.redo();
          expect((await s.annotations()).single.id, a.id);
          await expectLater(
            s.recolorHighlights({a.id}, 0xff0000ff, s.revision),
            throwsUnsupportedError,
          );
          expect((await s.annotations()).single.argb, 0xffff0000);
          // Save before any render so the stored PDF needs its own appearance.
          await s.save();
          final reopened = await PdfSession.open(file.path);
          try {
            final restored = (await reopened.annotations()).single;
            expect(restored.kind, AnnotationKind.underline);
            expect(restored.argb, 0xffff0000);
            expect(restored.canEdit, true);
            expect(restored.canRecolor, false);
            expect(restored.pdfName, a.pdfName);
            expect(restored.quads, a.quads);
            expect(
              await pdfiumDocumentTask(
                reopened.lease.document,
                _annotations,
                1,
              ),
              [(subtype: FPDF_ANNOT_UNDERLINE, appearance: true)],
            );
            final page = reopened.lease.document.pages.first;
            final image = (await page.render(
              fullWidth: page.width * 2,
              fullHeight: page.height * 2,
            ))!;
            try {
              var red = 0;
              for (var i = 0; i < image.pixels.length; i += 4) {
                if (image.pixels[i + 2] > 240 &&
                    image.pixels[i + 1] < 30 &&
                    image.pixels[i] < 30) {
                  red++;
                }
              }
              // A thin opaque line, not a translucent filled highlight.
              expect(red, greaterThan(100));
              expect(red, lessThan(1800));
            } finally {
              image.dispose();
            }
            await reopened.removeAnnotations({restored.id}, reopened.revision);
            expect(reopened.undoLabel, 'Remove underline');
            await reopened.save();
            final deleted = await PdfDocument.openFile(file.path);
            try {
              expect(
                await pdfiumDocumentTask(deleted, _annotations, 1),
                isEmpty,
              );
            } finally {
              await deleted.dispose();
            }
            await reopened.undo();
            await reopened.save();
            final undo = await PdfSession.open(file.path);
            try {
              final record = (await undo.annotations()).single;
              expect(record.kind, AnnotationKind.underline);
              expect(record.argb, 0xffff0000);
              expect(record.canEdit, true);
            } finally {
              await undo.close(discard: true);
            }
            if (Platform.isMacOS) {
              final result = await Process.run(pdfkit, [file.path]);
              expect(result.exitCode, 0, reason: '${result.stderr}');
              final reading = jsonDecode(result.stdout as String) as Map;
              expect(reading['types'], ['Underline']);
              expect(reading['appearances'], [true]);
              expect(reading['redPixels'], inExclusiveRange(100, 1800));
              final artifacts = Directory('build/test-artifacts')
                ..createSync(recursive: true);
              await File('${file.path}.png')
                  .copy('${artifacts.path}/underline-pdfkit-$rotation.png');
            }
          } finally {
            await reopened.close(discard: true);
          }
        } finally {
          await s.close(discard: true);
        }
      },
    );
  }

  test(
    'highlighting an underline preserves it through history and saving',
    () async {
      final file = File('${temp.path}/highlight-underline.pdf');
      await file.writeAsBytes(spacedTextPdf());
      final s = await PdfSession.open(file.path);
      try {
        await s.underline(_regions);
        final underline = (await s.annotations()).single;
        await expectLater(
          s.highlightUnderline(underline.id, 0x66ffeb3b, s.revision - 1),
          throwsStateError,
        );
        expect(await s.annotations(), hasLength(1));
        await s.highlightUnderline(underline.id, 0x66ffeb3b, s.revision);
        final marks = await s.annotations();
        final highlight = marks.last;
        expect(marks, hasLength(2));
        expect(marks.first.id, underline.id);
        expect(marks.first.argb, underline.argb);
        expect(marks.first.quads, underline.quads);
        expect(highlight.kind, AnnotationKind.highlight);
        expect(highlight.id, isNot(underline.id));
        expect(highlight.quads, underline.quads);
        expect(highlight.bounds, underline.bounds);
        expect(highlight.argb, 0x66ffeb3b);
        expect(highlight.contents, isEmpty);
        expect(highlight.author, isEmpty);
        expect(s.undoLabel, 'Add highlight');
        await expectLater(
          s.highlightUnderline(highlight.id, 0x66ffeb3b, s.revision),
          throwsArgumentError,
        );
        await s.undo();
        expect((await s.annotations()).single.id, underline.id);
        await s.redo();
        expect((await s.annotations()).last.id, highlight.id);
        await s.save();
        final reopened = await PdfSession.open(file.path);
        try {
          final restored = await reopened.annotations();
          expect(restored.map((a) => a.kind), [
            AnnotationKind.underline,
            AnnotationKind.highlight,
          ]);
          expect(restored.map((a) => a.argb), [0xffff0000, 0x66ffeb3b]);
          expect(restored.last.quads, restored.first.quads);
          expect(restored.every((a) => a.canEdit), true);
        } finally {
          await reopened.close(discard: true);
        }
      } finally {
        await s.close(discard: true);
      }
    },
  );

  test('multi-page selection is one reversible underline action', () async {
    final file = File('${temp.path}/multi-page.pdf');
    await file.writeAsBytes(pdfFixture());
    final s = await PdfSession.open(file.path);
    try {
      final ranges = <PdfPageTextRange>[];
      for (final page in s.lease.document.pages) {
        final text = await page.loadStructuredText();
        ranges.add(
          PdfPageTextRange(pageText: text, start: 0, end: text.fullText.length),
        );
      }
      await s.underline(
        HighlightRegion.fromTextRanges(ranges, includeText: false),
      );
      final marks = await s.annotations();
      expect(marks.map((a) => a.pageNumber), [1, 2, 3]);
      expect(marks.every((a) => a.kind == AnnotationKind.underline), true);
      await s.undo();
      expect(await s.annotations(), isEmpty);
      expect(s.canUndo, false);
      await s.redo();
      expect((await s.annotations()).map((a) => a.id), marks.map((a) => a.id));
      await s.save();
      final reopened = await PdfSession.open(file.path);
      try {
        expect(
          (await reopened.annotations()).map((a) => a.kind),
          List.filled(3, AnnotationKind.underline),
        );
        expect((await reopened.annotations()).every((a) => a.canEdit), true);
      } finally {
        await reopened.close(discard: true);
      }
    } finally {
      await s.close(discard: true);
    }
  });

  test(
    'foreign and unsupported underline appearances remain read-only',
    () async {
      for (final name in ['foreign', 'PoDoFo:unsupported']) {
        final file = File('${temp.path}/import-${name.length}.pdf');
        await file.writeAsBytes(
          annotationPdf(
            relationships: false,
            firstSubtype: 'Underline',
            firstName: name,
            author: 'PoDoFo',
          ),
        );
        final s = await PdfSession.open(file.path);
        try {
          final mark = (await s.annotations()).first;
          expect(mark.kind, AnnotationKind.underline);
          expect(mark.owned, name.startsWith('PoDoFo:'));
          expect(mark.canEdit, false);
          await expectLater(
            s.removeAnnotations({mark.id}, s.revision),
            mark.owned ? throwsUnsupportedError : throwsStateError,
          );
          expect(s.canUndo, false);
          expect((await s.annotations()).first.pdfName, name);
        } finally {
          await s.close(discard: true);
        }
      }
    },
  );

  test(
    'batch rollback recovery and mixed deletion preserve annotation kinds',
    () async {
      final file = File('${temp.path}/recovery.pdf');
      await file.writeAsBytes(pdfFixture());
      final faults = AnnotationFaults();
      final s = await PdfSession.open(
        file.path,
        annotationAdapter: PdfAnnotationAdapter(faults: faults),
      );
      try {
        await s.highlight(_regions, 0x66ffff00);
        await s.underline([
          const HighlightRegion(2, [PdfRect(20, 100, 110, 80)]),
        ]);
        final original = await s.annotations();
        faults.failAfterChanges = 1;
        faults.failRollback = true;
        await expectLater(
          s.underline([
            const HighlightRegion(1, [PdfRect(20, 100, 110, 80)]),
            const HighlightRegion(3, [PdfRect(20, 100, 110, 80)]),
          ]),
          throwsA(isA<AnnotationMutationFailure>()),
        );
        expect(
          (await s.annotations()).map((a) => a.kind),
          original.map((a) => a.kind),
        );
        expect(
          (await pdfiumDocumentTask(
            s.lease.document,
            _annotations,
            2,
          )).single.subtype,
          FPDF_ANNOT_UNDERLINE,
        );
        await s.removeAnnotations(
          original.map((a) => a.id).toSet(),
          s.revision,
        );
        expect(s.undoLabel, 'Remove annotations');
        await s.save();
        await s.undo();
        await s.save();
        final reopened = await PdfSession.open(file.path);
        try {
          expect((await reopened.annotations()).map((a) => a.kind), [
            AnnotationKind.highlight,
            AnnotationKind.underline,
          ]);
          expect((await reopened.annotations()).every((a) => a.canEdit), true);
        } finally {
          await reopened.close(discard: true);
        }
      } finally {
        await s.close(discard: true);
      }
    },
  );
}
