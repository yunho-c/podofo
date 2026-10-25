import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import '../services/pdf_highlights.dart';
import 'annotation_edit.dart';
import 'pdfium_document_task.dart';

typedef AnnotationLocation = ({int pageNumber, int index});

/// Deterministic failure injection for transaction/recovery tests. Never contains
/// callbacks or native objects that could escape their owning isolate.
class AnnotationFaults {
  int? failAfterChanges;
  bool failRollback = false;
  bool failRecovery = false;
  bool failExport = false;
}

class AnnotationMutationFailure implements Exception {
  AnnotationMutationFailure(this.message, this.rollbackFailed);
  final String message;
  final bool rollbackFailed;
  @override
  String toString() => message;
}

/// Session-local locators and compact tombstones. The live PDF is edited on its
/// owning worker. Serialization occurs only for export, never for history.
class PdfAnnotationAdapter {
  PdfAnnotationAdapter({AnnotationFaults? faults})
    : faults = faults ?? AnnotationFaults();
  final AnnotationFaults faults;
  final _prefix = List.generate(
    4,
    (_) =>
        Random.secure().nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
  ).join();
  int _nextId = 0;
  Map<String, AnnotationLocation> _locations = {};
  Map<String, AnnotationRecord> _baseline = {};
  final _catalog = <String, AnnotationRecord>{};
  final _tombstones = <String>{};
  final _nextOrder = <int, int>{};

  Future<Map<String, AnnotationRecord>> initialize(PdfDocument pdf) async {
    final scan = await pdfiumDocumentTask(pdf, _scan, _prefix);
    _baseline = Map.unmodifiable(scan.records);
    _catalog.addAll(scan.records);
    _locations = {
      for (final a in scan.records.values)
        a.id: (pageNumber: a.pageNumber, index: a.index),
    };
    _nextOrder.addAll(scan.counts);
    return Map.of(scan.records);
  }

  AnnotationRecord located(AnnotationRecord record) =>
      record.copyWith(index: _locations[record.id]!.index);

  AnnotationEdit create(
    PdfDocument pdf,
    List<HighlightRegion> regions,
    int argb,
  ) {
    if (argb < 0 || argb > 0xffffffff) throw ArgumentError('Invalid color.');
    final changes = <AnnotationChange>[];
    for (final region in regions) {
      if (region.pageNumber < 1 ||
          region.pageNumber > pdf.pages.length ||
          region.rects.isEmpty ||
          region.rects.any(
            (r) =>
                ![r.left, r.top, r.right, r.bottom].every((v) => v.isFinite) ||
                r.width <= 0 ||
                r.height <= 0,
          )) {
        throw ArgumentError('Invalid highlight geometry.');
      }
      final id = '${AnnotationRecord.pdfNamePrefix}$_prefix-new-${_nextId++}';
      final index = _nextOrder.update(region.pageNumber, (n) => n + 1) - 1;
      final left = region.rects.map((r) => r.left).reduce(min);
      final right = region.rects.map((r) => r.right).reduce(max);
      final top = region.rects.map((r) => r.top).reduce(max);
      final bottom = region.rects.map((r) => r.bottom).reduce(min);
      final record = AnnotationRecord(
        id: id,
        pageNumber: region.pageNumber,
        index: index,
        contents: '',
        author: '',
        pdfName: id,
        flags: FPDF_ANNOT_FLAG_PRINT,
        argb: argb,
        hasAppearance: false,
        bounds: [left, top, right, bottom],
        quads: [
          for (final r in region.rects)
            [
              r.left,
              r.top,
              r.right,
              r.top,
              r.left,
              r.bottom,
              r.right,
              r.bottom,
            ],
        ],
      );
      changes.add(AnnotationChange(id: id, after: record));
    }
    return AnnotationEdit(label: 'Add highlight', changes: changes);
  }

  List<AnnotationRecord> _targets(
    Map<String, AnnotationRecord> model,
    Set<String> ids,
  ) {
    if (ids.isEmpty) throw ArgumentError('No highlights selected.');
    return [
      for (final id in ids)
        (() {
          final a = model[id];
          if (a == null) throw StateError('Highlight no longer exists.');
          if (!a.owned) {
            throw StateError(
              'Only highlights authored by PoDoFo can be edited.',
            );
          }
          if (a.locked) throw StateError('This highlight is locked.');
          if (!a.canEdit || a.bounds.length != 4) {
            throw UnsupportedError(
              'This highlight cannot be represented as a standard single-color highlight.',
            );
          }
          return a;
        })(),
    ];
  }

  AnnotationEdit? recolor(
    Map<String, AnnotationRecord> model,
    Set<String> ids,
    int argb,
  ) {
    if (argb < 0 || argb > 0xffffffff) throw ArgumentError('Invalid color.');
    final changes = [
      for (final a in _targets(model, ids))
        if (a.argb != argb)
          AnnotationChange(
            id: a.id,
            before: a,
            after: a.copyWith(argb: argb),
          ),
    ];
    return changes.isEmpty
        ? null
        : AnnotationEdit(label: 'Change highlight color', changes: changes);
  }

  AnnotationEdit remove(Map<String, AnnotationRecord> model, Set<String> ids) =>
      AnnotationEdit(
        label: ids.length == 1 ? 'Remove highlight' : 'Remove highlights',
        changes: [
          for (final a in _targets(model, ids))
            AnnotationChange(id: a.id, before: a),
        ],
      );

  Future<void> apply(PdfDocument pdf, AnnotationEdit edit) async {
    if (pdf.permissions?.allowsModifyAnnotations == false) {
      throw StateError('This PDF does not allow annotation changes.');
    }
    final request = _ApplyRequest(
      edit.changes,
      Map.of(_locations),
      faults.failAfterChanges,
      faults.failRollback,
    );
    faults.failAfterChanges = null;
    faults.failRollback = false;
    final result = await pdfiumDocumentTask(pdf, _apply, request);
    if (result.error != null) {
      throw AnnotationMutationFailure(result.error!, result.rollbackFailed);
    }
    _locations.addAll(result.locations);
    for (final change in edit.changes) {
      _catalog[change.id] = change.after ?? change.before!;
      if (change.after == null) {
        _tombstones.add(change.id);
      } else {
        _tombstones.remove(change.id);
      }
    }
  }

  Future<void> recover(
    PdfDocument candidate,
    Map<String, AnnotationRecord> current,
  ) async {
    if (faults.failRecovery) {
      faults.failRecovery = false;
      throw StateError('Injected recovery failure.');
    }
    final records = {..._baseline, ..._catalog, ...current};
    final result = await pdfiumDocumentTask(
      candidate,
      _recover,
      _RecoveryRequest(_baseline, records, current),
    );
    _locations = result;
    _catalog
      ..clear()
      ..addAll(records);
    _tombstones
      ..clear()
      ..addAll(records.keys.where((id) => !current.containsKey(id)));
  }

  Future<Set<int>> collect(PdfDocument pdf, Set<String> retainedIds) async {
    final removed = _tombstones.difference(retainedIds);
    if (removed.isEmpty) return {};
    final locations = [for (final id in removed) _locations[id]!];
    await pdfiumDocumentTask(pdf, _removeSlots, locations);
    final previous = _locations;
    _locations = {
      for (final entry in previous.entries)
        if (!removed.contains(entry.key))
          entry.key: (
            pageNumber: entry.value.pageNumber,
            index:
                entry.value.index -
                locations
                    .where(
                      (p) =>
                          p.pageNumber == entry.value.pageNumber &&
                          p.index < entry.value.index,
                    )
                    .length,
          ),
    };
    for (final id in removed) {
      _catalog.remove(id);
      _tombstones.remove(id);
    }
    return locations.map((location) => location.pageNumber).toSet();
  }

  Future<Uint8List> export(PdfDocument pdf) async {
    if (faults.failExport) {
      faults.failExport = false;
      throw StateError('Injected export failure.');
    }
    final bytes = await pdf.encodePdf();
    if (_tombstones.isEmpty) return bytes;
    final candidate = await PdfDocument.openData(
      bytes,
      sourceName: 'annotation-export',
      useProgressiveLoading: false,
    );
    try {
      await pdfiumDocumentTask(candidate, _removeSlots, [
        for (final id in _tombstones) _locations[id]!,
      ]);
      return await candidate.encodePdf();
    } finally {
      await candidate.dispose();
    }
  }
}

class _Scan {
  _Scan(this.records, this.counts);
  final Map<String, AnnotationRecord> records;
  final Map<int, int> counts;
}

_Scan _scan(int handle, String prefix) {
  final e = _NativeEditor(handle);
  final records = <String, AnnotationRecord>{}, counts = <int, int>{};
  for (
    var number = 1;
    number <= e.api.FPDF_GetPageCount(e.document);
    number++
  ) {
    e.page(number, (page) {
      counts[number] = e.api.FPDFPage_GetAnnotCount(page);
      for (var index = 0; index < counts[number]!; index++) {
        e.annotation(page, index, (annot) {
          if (e.api.FPDFAnnot_GetSubtype(annot) == FPDF_ANNOT_HIGHLIGHT) {
            final id = '$prefix-p$number-a$index';
            records[id] = e.read(page, annot, id, number, index);
          }
        });
      }
    });
  }
  return _Scan(records, counts);
}

class _ApplyRequest {
  _ApplyRequest(
    this.changes,
    this.locations,
    this.failAfter,
    this.failRollback,
  );
  final List<AnnotationChange> changes;
  final Map<String, AnnotationLocation> locations;
  final int? failAfter;
  final bool failRollback;
}

class _ApplyResult {
  _ApplyResult(this.locations, [this.error, this.rollbackFailed = false]);
  final Map<String, AnnotationLocation> locations;
  final String? error;
  final bool rollbackFailed;
}

_ApplyResult _apply(int handle, _ApplyRequest request) {
  final e = _NativeEditor(handle);
  e.editable();
  // Preflight every existing target and relationship before the first mutation.
  final deleting = <AnnotationLocation>[];
  for (final change in request.changes) {
    final record = change.after ?? change.before!;
    if (!record.canEdit) throw StateError('Highlight is not editable.');
    final location = request.locations[change.id];
    if (location != null) {
      e.page(
        location.pageNumber,
        (p) => e.annotation(p, location.index, (a) {
          if (e.api.FPDFAnnot_GetSubtype(a) != FPDF_ANNOT_HIGHLIGHT ||
              !AnnotationRecord.isPoDoFoHighlight(
                e.string(a, 'NM'),
                e.string(a, 'T'),
              ) ||
              e.api.FPDFAnnot_GetFlags(a) & (64 | 128 | 512) != 0) {
            throw StateError('Highlight changed or is locked.');
          }
        }),
      );
    }
    if (change.after == null && location != null) deleting.add(location);
  }
  e.checkRelationships(deleting);
  final changed =
      <
        ({AnnotationChange change, AnnotationLocation location, bool created})
      >[];
  final locations = <String, AnnotationLocation>{};
  try {
    for (final change in request.changes) {
      if (request.failAfter == changed.length) {
        throw StateError('Injected native edit failure.');
      }
      final record = change.after ?? change.before!;
      e.page(record.pageNumber, (page) {
        var location = request.locations[change.id];
        final created = location == null;
        FPDF_ANNOTATION annot;
        if (created) {
          location = (
            pageNumber: record.pageNumber,
            index: e.api.FPDFPage_GetAnnotCount(page),
          );
          annot = e.api.FPDFPage_CreateAnnot(page, FPDF_ANNOT_HIGHLIGHT);
        } else {
          annot = e.api.FPDFPage_GetAnnot(page, location.index);
        }
        if (annot == nullptr) throw StateError('Cannot open highlight.');
        changed.add((change: change, location: location, created: created));
        locations[change.id] = location;
        try {
          if (change.after case final after?) {
            e.write(page, annot, after);
          } else {
            e.hide(annot, record.flags);
          }
        } finally {
          e.api.FPDFPage_CloseAnnot(annot);
        }
      });
    }
    if (request.failAfter == changed.length) {
      throw StateError('Injected native edit failure.');
    }
    return _ApplyResult(locations);
  } catch (error) {
    var rollbackFailed = false;
    for (final item in changed.reversed) {
      try {
        if (request.failRollback) {
          throw StateError('Injected rollback failure.');
        }
        e.page(item.location.pageNumber, (page) {
          if (item.created) {
            e.check(e.api.FPDFPage_RemoveAnnot(page, item.location.index));
          } else {
            e.annotation(page, item.location.index, (annot) {
              if (item.change.before case final before?) {
                e.write(page, annot, before);
              } else {
                e.hide(annot, item.change.after!.flags);
              }
            });
          }
        });
      } catch (_) {
        rollbackFailed = true;
      }
    }
    return _ApplyResult({}, error.toString(), rollbackFailed);
  }
}

class _RecoveryRequest {
  _RecoveryRequest(this.baseline, this.catalog, this.current);
  final Map<String, AnnotationRecord> baseline, catalog, current;
}

Map<String, AnnotationLocation> _recover(int handle, _RecoveryRequest request) {
  final e = _NativeEditor(handle);
  final locations = <String, AnnotationLocation>{};
  for (final original in request.baseline.values) {
    locations[original.id] = (
      pageNumber: original.pageNumber,
      index: original.index,
    );
    final current = request.current[original.id];
    if (!original.owned || identical(current, original)) continue;
    e.page(
      original.pageNumber,
      (page) => e.annotation(page, original.index, (annot) {
        if (current == null) {
          e.hide(annot, original.flags);
        } else {
          e.write(page, annot, current);
        }
      }),
    );
  }
  final added =
      request.catalog.values
          .where((a) => !request.baseline.containsKey(a.id))
          .toList()
        ..sort((a, b) {
          final page = a.pageNumber.compareTo(b.pageNumber);
          return page != 0 ? page : a.index.compareTo(b.index);
        });
  for (final record in added) {
    e.page(record.pageNumber, (page) {
      final index = e.api.FPDFPage_GetAnnotCount(page);
      final annot = e.api.FPDFPage_CreateAnnot(page, FPDF_ANNOT_HIGHLIGHT);
      if (annot == nullptr) throw StateError('Cannot restore highlight.');
      try {
        e.write(page, annot, request.current[record.id] ?? record);
        if (!request.current.containsKey(record.id)) {
          e.hide(annot, record.flags);
        }
        locations[record.id] = (pageNumber: record.pageNumber, index: index);
      } finally {
        e.api.FPDFPage_CloseAnnot(annot);
      }
    });
  }
  return locations;
}

void _removeSlots(int handle, List<AnnotationLocation> locations) {
  final e = _NativeEditor(handle);
  final sorted = [...locations]
    ..sort((a, b) {
      final page = b.pageNumber.compareTo(a.pageNumber);
      return page != 0 ? page : b.index.compareTo(a.index);
    });
  for (final location in sorted) {
    e.page(
      location.pageNumber,
      (page) => e.check(e.api.FPDFPage_RemoveAnnot(page, location.index)),
    );
  }
}

class _NativeEditor {
  _NativeEditor(int handle)
    : document = Pointer<fpdf_document_t__>.fromAddress(handle);
  final FPDF_DOCUMENT document;
  final PDFium api = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
  void check(int result) {
    if (result == 0) throw StateError('PDFium could not update the highlight.');
  }

  void editable() {
    if (api.FPDF_GetSignatureCount(document) > 0) {
      throw StateError('Digitally signed PDFs cannot be edited.');
    }
  }

  T page<T>(int number, T Function(FPDF_PAGE) action) {
    final p = api.FPDF_LoadPage(document, number - 1);
    if (p == nullptr) throw StateError('Cannot load page.');
    try {
      return action(p);
    } finally {
      api.FPDF_ClosePage(p);
    }
  }

  T annotation<T>(
    FPDF_PAGE page,
    int index,
    T Function(FPDF_ANNOTATION) action,
  ) {
    final a = api.FPDFPage_GetAnnot(page, index);
    if (a == nullptr) throw StateError('Cannot read highlight.');
    try {
      return action(a);
    } finally {
      api.FPDFPage_CloseAnnot(a);
    }
  }

  String string(FPDF_ANNOTATION a, String name) => using((arena) {
    final key = name.toNativeUtf8(allocator: arena).cast<Char>();
    final n = api.FPDFAnnot_GetStringValue(a, key, nullptr, 0);
    if (n < 2) return '';
    if (n > 16 * 1024 * 1024) {
      throw UnsupportedError('Annotation metadata is too large.');
    }
    final buffer = arena<Uint16>(n ~/ 2);
    api.FPDFAnnot_GetStringValue(a, key, buffer.cast(), n);
    return buffer.cast<Utf16>().toDartString(length: n ~/ 2 - 1);
  });
  void setString(FPDF_ANNOTATION a, String name, String value, Arena arena) {
    check(
      api.FPDFAnnot_SetStringValue(
        a,
        name.toNativeUtf8(allocator: arena).cast(),
        value.toNativeUtf16(allocator: arena).cast(),
      ),
    );
  }

  int? color(FPDF_ANNOTATION a, bool owned) => using((arena) {
    final channels = arena<UnsignedInt>(4);
    int packed() =>
        (channels[3] << 24) |
        (channels[0] << 16) |
        (channels[1] << 8) |
        channels[2];
    if (api.FPDFAnnot_GetColor(
          a,
          FPDFANNOT_COLORTYPE.FPDFANNOT_COLORTYPE_Color,
          channels,
          channels + 1,
          channels + 2,
          channels + 3,
        ) !=
        0) {
      return packed();
    }
    if (!owned) return null;
    int? result;
    var valid = true, objects = 0;
    void inspect(FPDF_PAGEOBJECT object, int depth, double alpha) {
      if (object == nullptr || depth > 16 || ++objects > 4096) {
        valid = false;
        return;
      }
      final type = api.FPDFPageObj_GetType(object);
      if (type == FPDF_PAGEOBJ_FORM) {
        // Form transparency multiplies the nested path alpha.
        if (api.FPDFPageObj_GetFillColor(
              object,
              channels,
              channels + 1,
              channels + 2,
              channels + 3,
            ) ==
            0) {
          valid = false;
          return;
        }
        final formAlpha = channels[3] / 255;
        for (var i = 0; i < api.FPDFFormObj_CountObjects(object); i++) {
          inspect(
            api.FPDFFormObj_GetObject(object, i),
            depth + 1,
            alpha * formAlpha,
          );
        }
      } else if (type == FPDF_PAGEOBJ_PATH) {
        final fill = arena<Int>(), stroke = arena<Int>();
        if (api.FPDFPath_GetDrawMode(object, fill, stroke) == 0 ||
            fill.value == 0 ||
            stroke.value != 0 ||
            api.FPDFPageObj_GetFillColor(
                  object,
                  channels,
                  channels + 1,
                  channels + 2,
                  channels + 3,
                ) ==
                0) {
          valid = false;
          return;
        }
        channels[3] = (channels[3] * alpha).round();
        final value = packed();
        if (result != null && result != value) valid = false;
        result = value;
      } else {
        valid = false;
      }
    }

    for (var i = 0; i < api.FPDFAnnot_GetObjectCount(a); i++) {
      inspect(api.FPDFAnnot_GetObject(a, i), 0, 1);
    }
    return valid ? result : null;
  });
  AnnotationRecord read(
    FPDF_PAGE page,
    FPDF_ANNOTATION a,
    String id,
    int number,
    int index,
  ) => using((arena) {
    final box = arena<FS_RECTF>(), rect = arena<FS_RECTF>();
    check(api.FPDF_GetPageBoundingBox(page, box));
    check(api.FPDFAnnot_GetRect(a, rect));
    final quad = arena<FS_QUADPOINTSF>(), quads = <List<double>>[];
    for (var i = 0; i < api.FPDFAnnot_CountAttachmentPoints(a); i++) {
      check(api.FPDFAnnot_GetAttachmentPoints(a, i, quad));
      quads.add([
        quad.ref.x1 - box.ref.left,
        quad.ref.y1 - box.ref.bottom,
        quad.ref.x2 - box.ref.left,
        quad.ref.y2 - box.ref.bottom,
        quad.ref.x3 - box.ref.left,
        quad.ref.y3 - box.ref.bottom,
        quad.ref.x4 - box.ref.left,
        quad.ref.y4 - box.ref.bottom,
      ]);
    }
    final author = string(a, 'T');
    final pdfName = string(a, 'NM');
    return AnnotationRecord(
      id: id,
      pageNumber: number,
      index: index,
      contents: string(a, 'Contents'),
      author: author,
      pdfName: pdfName,
      flags: api.FPDFAnnot_GetFlags(a),
      argb: color(a, AnnotationRecord.isPoDoFoHighlight(pdfName, author)),
      hasAppearance:
          api.FPDFAnnot_HasKey(a, 'AP'.toNativeUtf8(allocator: arena).cast()) !=
          0,
      quads: quads,
      bounds: [
        rect.ref.left - box.ref.left,
        rect.ref.top - box.ref.bottom,
        rect.ref.right - box.ref.left,
        rect.ref.bottom - box.ref.bottom,
      ],
      created: string(a, 'CreationDate'),
      modified: string(a, 'M'),
      subject: string(a, 'Subj'),
    );
  });
  void hide(FPDF_ANNOTATION a, int flags) => check(
    api.FPDFAnnot_SetFlags(
      a,
      (flags | FPDF_ANNOT_FLAG_HIDDEN | FPDF_ANNOT_FLAG_NOVIEW) &
          ~FPDF_ANNOT_FLAG_PRINT,
    ),
  );
  void write(
    FPDF_PAGE page,
    FPDF_ANNOTATION a,
    AnnotationRecord record,
  ) => using((arena) {
    if (!record.canEdit || record.bounds.length != 4) {
      throw StateError('Invalid highlight record.');
    }
    final box = arena<FS_RECTF>(), rect = arena<FS_RECTF>();
    check(api.FPDF_GetPageBoundingBox(page, box));
    check(api.FPDFAnnot_SetAP(a, FPDF_ANNOT_APPEARANCEMODE_NORMAL, nullptr));
    rect.ref
      ..left = record.bounds[0] + box.ref.left
      ..top = record.bounds[1] + box.ref.bottom
      ..right = record.bounds[2] + box.ref.left
      ..bottom = record.bounds[3] + box.ref.bottom;
    check(api.FPDFAnnot_SetRect(a, rect));
    final existing = api.FPDFAnnot_CountAttachmentPoints(a),
        quad = arena<FS_QUADPOINTSF>();
    if (existing != 0 && existing != record.quads.length) {
      throw StateError('Highlight geometry changed.');
    }
    for (var i = 0; i < record.quads.length; i++) {
      final q = record.quads[i];
      quad.ref
        ..x1 = q[0] + box.ref.left
        ..y1 = q[1] + box.ref.bottom
        ..x2 = q[2] + box.ref.left
        ..y2 = q[3] + box.ref.bottom
        ..x3 = q[4] + box.ref.left
        ..y3 = q[5] + box.ref.bottom
        ..x4 = q[6] + box.ref.left
        ..y4 = q[7] + box.ref.bottom;
      check(
        i < existing
            ? api.FPDFAnnot_SetAttachmentPoints(a, i, quad)
            : api.FPDFAnnot_AppendAttachmentPoints(a, quad),
      );
    }
    final argb = record.argb!;
    check(
      api.FPDFAnnot_SetColor(
        a,
        FPDFANNOT_COLORTYPE.FPDFANNOT_COLORTYPE_Color,
        (argb >> 16) & 255,
        (argb >> 8) & 255,
        argb & 255,
        (argb >> 24) & 255,
      ),
    );
    check(api.FPDFAnnot_SetFlags(a, record.flags));
    // Omit unused comment fields on new highlights; preserve existing fields.
    for (final entry in {
      'T': record.author,
      'Contents': record.contents,
    }.entries) {
      if (entry.value.isNotEmpty ||
          api.FPDFAnnot_HasKey(
                a,
                entry.key.toNativeUtf8(allocator: arena).cast(),
              ) !=
              0) {
        setString(a, entry.key, entry.value, arena);
      }
    }
    if (record.pdfName.isNotEmpty) setString(a, 'NM', record.pdfName, arena);
    if (record.created.isNotEmpty) {
      setString(a, 'CreationDate', record.created, arena);
    }
    if (record.modified.isNotEmpty) setString(a, 'M', record.modified, arena);
    if (record.subject.isNotEmpty) setString(a, 'Subj', record.subject, arena);
  });

  void checkRelationships(List<AnnotationLocation> deleting) {
    if (deleting.isEmpty) return;
    using((arena) {
      final keys = {
        for (final name in ['Popup', 'IRT', 'Parent'])
          name: name.toNativeUtf8(allocator: arena).cast<Char>(),
      };
      for (
        var number = 1;
        number <= api.FPDF_GetPageCount(document);
        number++
      ) {
        page(number, (p) {
          for (var i = 0; i < api.FPDFPage_GetAnnotCount(p); i++) {
            annotation(p, i, (a) {
              for (final key in keys.entries) {
                if (key.key == 'Parent' &&
                    api.FPDFAnnot_GetSubtype(a) != FPDF_ANNOT_POPUP) {
                  continue;
                }
                final linked = api.FPDFAnnot_GetLinkedAnnot(a, key.value);
                if (linked == nullptr) continue;
                try {
                  if (deleting.contains((pageNumber: number, index: i))) {
                    throw UnsupportedError(
                      'This highlight has related annotations.',
                    );
                  }
                  for (final target in deleting) {
                    final related = page(
                      target.pageNumber,
                      (targetPage) =>
                          api.FPDFPage_GetAnnotIndex(targetPage, linked) ==
                          target.index,
                    );
                    if (related) {
                      throw UnsupportedError(
                        'This highlight has related annotations.',
                      );
                    }
                  }
                } finally {
                  api.FPDFPage_CloseAnnot(linked);
                }
              }
            });
          }
        });
      }
    });
  }
}
