import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';
import 'package:podofo_one/src/editing/annotation_edit.dart';
import 'package:podofo_one/src/editing/editable_pdf_document.dart';
import 'package:podofo_one/src/editing/pdf_annotation_adapter.dart';
import 'package:podofo_one/src/editing/pdfium_document_task.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/annotation_pdf.dart';
import 'fixtures/spaced_text_pdf.dart';

const regions = [
  HighlightRegion(1, [PdfRect(20, 120, 130, 100)], text: 'created'),
];
Future<Uint8List> pixels(PdfDocument pdf) async {
  final image = (await pdf.pages.first.render())!;
  try {
    return Uint8List.fromList(image.pixels);
  } finally {
    image.dispose();
  }
}

Future<List<({int flags, String text})>> slots(
  PdfDocument pdf, [
  int number = 1,
]) => pdfiumDocumentTask(pdf, _slots, number);
List<({int flags, String text})> _slots(int handle, int number) {
  final api = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
  final page = api.FPDF_LoadPage(
    Pointer<fpdf_document_t__>.fromAddress(handle),
    number - 1,
  );
  try {
    return using((arena) {
      final key = 'Contents'.toNativeUtf8(allocator: arena).cast<Char>();
      return [
        for (var i = 0; i < api.FPDFPage_GetAnnotCount(page); i++)
          (() {
            final a = api.FPDFPage_GetAnnot(page, i);
            try {
              final n = api.FPDFAnnot_GetStringValue(a, key, nullptr, 0);
              final buffer = arena<Uint16>(n < 2 ? 1 : n ~/ 2);
              api.FPDFAnnot_GetStringValue(a, key, buffer.cast(), n);
              return (
                flags: api.FPDFAnnot_GetFlags(a),
                text: n < 2
                    ? ''
                    : buffer.cast<Utf16>().toDartString(length: n ~/ 2 - 1),
              );
            } finally {
              api.FPDFPage_CloseAnnot(a);
            }
          })(),
      ];
    });
  } finally {
    api.FPDF_ClosePage(page);
  }
}

void _author(int handle, String author) {
  final api = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
  final p = api.FPDF_LoadPage(
    Pointer<fpdf_document_t__>.fromAddress(handle),
    0,
  );
  final a = api.FPDFPage_GetAnnot(p, 0);
  try {
    using((arena) {
      api.FPDFAnnot_SetStringValue(
        a,
        'T'.toNativeUtf8(allocator: arena).cast(),
        author.toNativeUtf16(allocator: arena).cast(),
      );
    });
  } finally {
    api.FPDFPage_CloseAnnot(a);
    api.FPDF_ClosePage(p);
  }
}

class _NoSerializationDocument extends EditablePdfDocument {
  _NoSerializationDocument(super.document);
  @override
  Future<Uint8List> encodePdf({
    bool incremental = false,
    bool removeSecurity = false,
  }) => throw StateError('Edits must not serialize the PDF.');
}

class _NoOpenBackend implements PdfrxEntryFunctions {
  _NoOpenBackend(this.delegate);
  final PdfrxEntryFunctions delegate;
  @override
  Future<R> compute<M, R>(FutureOr<R> Function(M) callback, M message) =>
      delegate.compute(callback, message);
  @override
  Future<T> suspendPdfiumWorkerDuringAction<T>(FutureOr<T> Function() action) =>
      delegate.suspendPdfiumWorkerDuringAction(action);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Edits must not reopen a PDF: ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  var serial = 0;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('podofo-owned-editing-');
    await pdfrxInitialize(tmpPath: temporary.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temporary.delete(recursive: true);
  });
  Future<PdfSession> open(
    Uint8List bytes, {
    int historyByteLimit = 64 * 1024 * 1024,
    int historyEntryLimit = 100,
    AnnotationFaults? faults,
  }) async {
    final file = File('${temporary.path}/${serial++}.pdf');
    await file.writeAsBytes(bytes);
    final session = await PdfSession.open(
      file.path,
      historyByteLimit: historyByteLimit,
      historyEntryLimit: historyEntryLimit,
      annotationAdapter: PdfAnnotationAdapter(faults: faults),
    );
    addTearDown(() => session.close(discard: true));
    return session;
  }

  test('create/recolor/delete and saved undo preserve ID, pixels and viewer identity', () async {
    final s = await open(spacedTextPdf());
    final document = s.lease.document;
    final before = await pixels(document);
    await s.highlight(regions, 0x66ffff00);
    final a = (await s.annotations()).single;
    expect(a.canEdit, true);
    final yellow = await pixels(document);
    await s.recolorHighlights({a.id}, 0x660000ff, s.revision);
    final blue = await pixels(document);
    expect(blue, isNot(yellow));
    await s.save();
    expect(s.dirty, false);
    expect(s.canUndo, true);
    await s.undo();
    expect(s.dirty, true);
    expect(await pixels(document), yellow);
    await s.redo();
    expect(s.dirty, false);
    expect(await pixels(document), blue);
    await s.removeAnnotations({a.id}, s.revision);
    expect(await s.annotations(), isEmpty);
    expect(await pixels(document), before);
    expect(
      (await slots(document)).single.flags & FPDF_ANNOT_FLAG_HIDDEN,
      isNot(0),
    );
    expect(await PdfHighlights.listPage(document, 1), isEmpty);
    await s.save();
    final removed = await PdfDocument.openFile(s.path);
    try {
      expect(await slots(removed), isEmpty);
    } finally {
      await removed.dispose();
    }
    await s.undo();
    expect((await s.annotations()).single.id, a.id);
    expect(await pixels(document), blue);
    expect(s.dirty, true);
    await s.save();
    final restored = await PdfDocument.openFile(s.path);
    try {
      expect(await pixels(restored), blue);
    } finally {
      await restored.dispose();
    }
    expect(s.lease.document, same(document));
  });

  test('exact author rule accepts legacy names and rejects foreign annotations without writes', () async {
    final s = await open(annotationPdf());
    final original = await File(s.path).readAsBytes();
    final records = await s.annotations();
    expect(records.every((a) => !a.canEdit), true);
    for (final a in records) {
      await expectLater(
        s.removeAnnotations({a.id}, s.revision),
        throwsStateError,
      );
      await expectLater(
        s.recolorHighlights({a.id}, 0xffff0000, s.revision),
        throwsStateError,
      );
    }
    expect(s.revision, 0);
    expect(s.dirty, false);
    await s.save();
    expect(await File(s.path).readAsBytes(), original);
    final owned = await open(
      annotationPdf(author: 'PoDoFo', relationships: false),
    );
    final legacy = await owned.annotations();
    expect(legacy.every((a) => a.canEdit), true);
    expect(legacy.map((a) => a.id).toSet(), hasLength(3));
    expect(legacy.where((a) => a.pdfName == 'duplicate'), hasLength(2));
    expect(legacy.last.pdfName, isEmpty);
    expect(owned.dirty, false);
  });

  test(
    'saving owned edits preserves foreign appearances and annotation order',
    () async {
      final s = await open(annotationPdf());
      final originalPixels = await pixels(s.lease.document);
      final originalSlots = await slots(s.lease.document);
      await s.highlight([
        const HighlightRegion(2, [PdfRect(20, 150, 130, 130)], text: 'owned'),
      ], 0x66ffff00);
      final owned = (await s.annotations()).singleWhere((a) => a.owned);
      await s.recolorHighlights({owned.id}, 0x660000ff, s.revision);
      await s.removeAnnotations({owned.id}, s.revision);
      await s.save();
      final reopened = await PdfDocument.openFile(s.path);
      try {
        expect(await pixels(reopened), originalPixels);
        expect(await slots(reopened), originalSlots);
        expect((await slots(reopened, 2)).map((a) => a.text), [
          'second page',
          '',
        ]);
        final saved = await File(s.path).readAsBytes();
        final pdfText = String.fromCharCodes(saved);
        expect(pdfText, contains('/PrivateData'));
        expect(pdfText, contains('opaque metadata'));
      } finally {
        await reopened.dispose();
      }
      await s.undo();
      expect((await s.annotations()).singleWhere((a) => a.owned).id, owned.id);
      expect(await pixels(s.lease.document), originalPixels);
    },
  );

  test('imported appearance color wins over stale dictionary color; undo normalizes it', () async {
    final s = await open(annotationPdf(author: 'PoDoFo', relationships: false));
    final a = (await s.annotations()).firstWhere((a) => a.contents == 'custom');
    expect(a.hasAppearance, true);
    expect(a.canRecolor, true);
    // /C says yellow; the actual appearance is green with 0.7 opacity.
    expect((a.argb! >> 16) & 255, inInclusiveRange(50, 52));
    expect((a.argb! >> 8) & 255, inInclusiveRange(203, 205));
    expect((a.argb! >> 24) & 255, inInclusiveRange(177, 179));
    await s.recolorHighlights({a.id}, 0x660000ff, s.revision);
    await s.undo();
    expect((await s.annotations()).first.argb, a.argb);
    await s.save();
    final reopened = await PdfSession.open(s.path);
    try {
      final restored = (await reopened.annotations()).first;
      expect(restored.argb, a.argb);
      expect(restored.canRecolor, true);
      await reopened.recolorHighlights(
        {restored.id},
        0x66ff0000,
        reopened.revision,
      );
    } finally {
      await reopened.close(discard: true);
    }
  });

  test(
    'deletion preserves original overlap order through undo and save',
    () async {
      final s = await open(
        annotationPdf(
          author: 'PoDoFo',
          relationships: false,
          overlapping: true,
        ),
      );
      final originalSlots = await slots(s.lease.document);
      final originalPixels = await pixels(s.lease.document);
      final a = (await s.annotations()).first;
      await s.removeAnnotations({a.id}, s.revision);
      expect(
        (await slots(s.lease.document)).map((a) => a.text),
        originalSlots.map((a) => a.text),
      );
      await s.save();
      await s.undo();
      expect(await slots(s.lease.document), originalSlots);
      // Appearance normalization may round edges, so establish that canonical
      // rendering and compare its subsequent delete/undo/save round trip.
      final canonical = await pixels(s.lease.document);
      expect(originalPixels.length, canonical.length);
      await s.removeAnnotations({a.id}, s.revision);
      await s.undo();
      expect(await pixels(s.lease.document), canonical);
      await s.save();
      final restored = await PdfDocument.openFile(s.path);
      try {
        expect(await slots(restored), originalSlots);
        expect(await pixels(restored), canonical);
      } finally {
        await restored.dispose();
      }
    },
  );

  test(
    'unsupported appearances and related annotations reject before mutation',
    () async {
      final unsupported = await open(
        annotationPdf(
          author: 'PoDoFo',
          relationships: false,
          unsupportedAppearance: true,
        ),
      );
      final custom = (await unsupported.annotations()).first;
      expect(custom.argb, isNull);
      expect(custom.canEdit, false);
      await expectLater(
        unsupported.recolorHighlights({custom.id}, 0xff0000ff, 0),
        throwsUnsupportedError,
      );
      final related = await open(
        annotationPdf(author: 'PoDoFo', crossPageReply: true),
      );
      final parent = (await related.annotations()).first;
      await expectLater(
        related.removeAnnotations({parent.id}, 0),
        throwsUnsupportedError,
      );
      expect(related.revision, 0);
      expect(related.canUndo, false);
    },
  );

  test('no-ops and stale selections preserve redo; branching reclaims unreachable slots', () async {
    final s = await open(spacedTextPdf());
    await s.highlight(regions, 0x66ffff00);
    final id = (await s.annotations()).single.id;
    await s.recolorHighlights({id}, 0x66ff0000, s.revision);
    await s.undo();
    final revision = s.revision;
    await s.recolorHighlights({id}, 0x66ffff00, revision);
    await s.highlight([], 0x66ffff00);
    await expectLater(
      s.removeAnnotations({id}, revision - 1),
      throwsStateError,
    );
    expect(s.revision, revision);
    expect(s.canRedo, true);
    await s.undo(); // creation is now a tombstone in the redo branch
    await s.highlight(regions, 0x660000ff);
    expect(s.canRedo, false);
    expect(await slots(s.lease.document), hasLength(1));
    final next = (await s.annotations()).single;
    expect(next.id, isNot(id));
    expect(next.index, 0);
    await s.undo();
    await s.redo();
    expect((await s.annotations()).single.id, next.id);
  });

  test(
    'late batch failures roll back and retain redo and saved marker',
    () async {
      final faults = AnnotationFaults();
      final s = await open(spacedTextPdf(), faults: faults);
      await s.highlight(regions, 0x66ffff00);
      final id = (await s.annotations()).single.id;
      await s.save();
      await s.recolorHighlights({id}, 0x660000ff, s.revision);
      await s.undo();
      final before = await pixels(s.lease.document), revision = s.revision;
      faults.failAfterChanges = 1;
      await expectLater(
        s.highlight([...regions, ...regions], 0x66ff0000),
        throwsA(isA<AnnotationMutationFailure>()),
      );
      expect(await slots(s.lease.document), hasLength(1));
      expect(await pixels(s.lease.document), before);
      expect(s.revision, revision);
      expect(s.canRedo, true);
      expect(s.dirty, false);
      faults.failAfterChanges = 1;
      await expectLater(
        s.recolorHighlights({id}, 0x66ff0000, s.revision),
        throwsA(isA<AnnotationMutationFailure>()),
      );
      expect(await pixels(s.lease.document), before);
      expect(s.canRedo, true);
    },
  );

  test('rollback failure reconstructs committed state; recovery failure disables saving', () async {
    final faults = AnnotationFaults();
    final s = await open(spacedTextPdf(), faults: faults);
    await s.highlight(regions, 0x66ffff00);
    final id = (await s.annotations()).single.id;
    final before = await pixels(s.lease.document),
        document = s.lease.document,
        revision = s.revision;
    faults
      ..failAfterChanges = 1
      ..failRollback = true;
    await expectLater(
      s.recolorHighlights({id}, 0x660000ff, revision),
      throwsA(isA<AnnotationMutationFailure>()),
    );
    expect(s.lease.document, same(document));
    expect(s.revision, revision);
    expect(await pixels(document), before);
    await s.undo();
    await s.redo();
    expect((await s.annotations()).single.id, id);
    faults
      ..failAfterChanges = 1
      ..failRollback = true
      ..failRecovery = true;
    await expectLater(
      s.recolorHighlights({id}, 0x66ff0000, s.revision),
      throwsStateError,
    );
    await expectLater(s.save(), throwsStateError);
    await expectLater(s.highlight(regions, 0x66ffff00), throwsStateError);
    expect(s.canUndo, false);
  });

  test('history budgets apply to annotation records and trimming keeps a saveable model', () async {
    final limited = await open(spacedTextPdf(), historyByteLimit: 100);
    await expectLater(limited.highlight(regions, 0x66ffff00), throwsStateError);
    expect(await slots(limited.lease.document), isEmpty);
    expect(limited.revision, 0);
    final s = await open(spacedTextPdf(), historyEntryLimit: 1);
    await s.highlight(regions, 0x66ffff00);
    final id = (await s.annotations()).single.id;
    await s.removeAnnotations({id}, s.revision);
    await s.highlight(regions, 0x660000ff); // prior deletion no longer undoable
    expect(await slots(s.lease.document), hasLength(1));
    await s.undo();
    expect(s.canUndo, false);
    expect(await s.annotations(), isEmpty);
    await s.save();
    final saved = await PdfDocument.openFile(s.path);
    try {
      expect(await slots(saved), isEmpty);
    } finally {
      await saved.dispose();
    }
  });

  test(
    'queued save/edit and failed exports or file conflicts preserve history',
    () async {
      final faults = AnnotationFaults();
      final s = await open(spacedTextPdf(), faults: faults);
      await s.highlight(regions, 0x66ffff00);
      final id = (await s.annotations()).single.id;
      final save = s.save(),
          edit = s.recolorHighlights({id}, 0x66ff0000, s.revision);
      await Future.wait([save, edit]);
      expect(s.dirty, true);
      await s.undo();
      expect(s.dirty, false);
      await s.redo();
      faults.failExport = true;
      await expectLater(s.save(), throwsStateError);
      expect(s.dirty, true);
      expect(s.canUndo, true);
      await File(s.path).writeAsBytes(spacedTextPdf(rotation: 90));
      await expectLater(s.save(), throwsStateError);
      expect(s.dirty, true);
    },
  );

  test(
    'streamed large PDFs edit on their owning worker without PDF-sized history',
    () async {
      final small = await open(
        annotationPdf(author: 'PoDoFo', relationships: false),
      );
      final large = await open(
        annotationPdf(
          author: 'PoDoFo',
          relationships: false,
          payloadBytes: 34 * 1024 * 1024,
        ),
      );
      expect(await File(large.path).length(), greaterThan(32 * 1024 * 1024));
      for (final s in [small, large]) {
        final imported = (await s.annotations()).first;
        expect(imported.canEdit, true);
        expect(await PdfHighlights.listPage(s.lease.document, 1), hasLength(2));
        await s.highlight(regions, 0x66ffff00);
        await s.recolorHighlights({imported.id}, 0x660000ff, s.revision);
        await s.removeAnnotations({imported.id}, s.revision);
        await s.undo();
        await s.redo();
        await pixels(s.lease.document);
      }
      expect(large.retainedHistoryBytes, small.retainedHistoryBytes);
      expect(large.retainedHistoryBytes, lessThan(16000));
      await large.save();
      final reopened = await PdfSession.open(large.path);
      try {
        expect(await reopened.annotations(), hasLength(3));
      } finally {
        await reopened.close(discard: true);
      }
      await large.undo();
      expect(await large.annotations(), hasLength(4));
    },
  );

  test('adapter edits never reopen or serialize the live PDF', () async {
    final raw = await PdfDocument.openData(spacedTextPdf());
    final pdf = _NoSerializationDocument(raw), adapter = PdfAnnotationAdapter();
    final original = PdfrxEntryFunctions.instance;
    PdfrxEntryFunctions.instance = _NoOpenBackend(original);
    try {
      final model = await adapter.initialize(pdf);
      final create = adapter.create(pdf, regions, 0x66ffff00);
      await adapter.apply(pdf, create);
      final a = create.changes.single.after!;
      model[a.id] = a;
      final recolor = adapter.recolor(model, {a.id}, 0x660000ff)!;
      await adapter.apply(pdf, recolor);
      model[a.id] = recolor.changes.single.after!;
      final remove = adapter.remove(model, {a.id});
      await adapter.apply(pdf, remove);
      await adapter.apply(
        pdf,
        AnnotationEdit(
          label: 'Undo',
          changes: [
            AnnotationChange(id: a.id, after: remove.changes.single.before),
          ],
        ),
      );
    } finally {
      PdfrxEntryFunctions.instance = original;
      await pdf.dispose();
    }
  });

  test(
    'PDFKit appearance survives reopening as an editable PoDoFo highlight',
    () async {
      final pdf = await PdfDocument.openData(
        await File('test/fixtures/pdfkit_highlight.pdf').readAsBytes(),
      );
      late Uint8List bytes;
      try {
        await pdfiumDocumentTask(pdf, _author, 'PoDoFo');
        bytes = await pdf.encodePdf();
      } finally {
        await pdf.dispose();
      }
      final s = await open(bytes);
      final a = (await s.annotations()).single;
      expect(a.hasAppearance, true);
      expect(a.canEdit, true);
      await s.recolorHighlights({a.id}, 0x660000ff, s.revision);
      await s.undo();
      await s.save();
      final reopened = await PdfSession.open(s.path);
      try {
        expect((await reopened.annotations()).single.argb, a.argb);
      } finally {
        await reopened.close(discard: true);
      }
    },
  );
}
