import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/editing/editable_pdf_document.dart';
import 'package:podofo_one/src/editing/pdfium_document_task.dart';

class FakeDocument implements PdfDocument {
  FakeDocument() {
    pages = [FakePage(this)];
  }
  final eventsController = StreamController<PdfDocumentEvent>.broadcast();
  int disposals = 0;
  @override
  String get sourceName => 'same-name.pdf';
  @override
  late List<PdfPage> pages;
  @override
  Stream<PdfDocumentEvent> get events => eventsController.stream;
  @override
  Future<void> dispose() async {
    disposals++;
    await eventsController.close();
  }

  @override
  Future<T> useNativeDocumentHandle<T>(FutureOr<T> Function(int) task) async =>
      await task(123);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakePage implements PdfPage {
  FakePage(this.document);
  final pending = Completer<PdfImage?>();
  @override
  final FakeDocument document;
  @override
  int get pageNumber => 1;
  @override
  double get width => 400;
  @override
  double get height => 200;
  @override
  PdfPageRotation get rotation => PdfPageRotation.none;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #render) return pending.future;
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test(
    'worker task pins the backing through handle capture, dispatch and close',
    () async {
      final original = PdfrxEntryFunctions.instance;
      final backend = HoldingBackend();
      PdfrxEntryFunctions.instance = backend;
      final native = FakeDocument();
      final document = EditablePdfDocument(native);
      try {
        final result = pdfiumDocumentTask(document, addHandle, 7);
        await backend.started.future;
        await document.dispose();
        expect(native.disposals, 0);
        backend.release.complete();
        expect(await result, 130);
        expect(native.disposals, 1);
      } finally {
        PdfrxEntryFunctions.instance = original;
      }
    },
  );

  test(
    'idle native release begins before dispose returns its future',
    () async {
      final native = FakeDocument();
      final document = EditablePdfDocument(native);
      final disposal = document.dispose();
      // pdfrx releases leases without awaiting dispose; shutdown may be queued
      // immediately afterward. Native close must already have been initiated.
      expect(native.disposals, 1);
      await disposal;
    },
  );

  test(
    'replacement and close pin native generations until active renders end',
    () async {
      final first = FakeDocument(), second = FakeDocument();
      final document = EditablePdfDocument(first);
      final observed = <PdfDocumentEvent>[];
      final subscription = document.events.listen(observed.add);
      final page = document.pages.single;
      final rendering = page.render();
      document.replace(second, {1});
      expect(first.disposals, 0);
      expect(second.disposals, 0);
      await Future<void>.delayed(Duration.zero);
      expect(observed.single.document, same(document));
      expect(
        (observed.single as PdfDocumentPageStatusChangedEvent).changes.keys,
        [1],
      );
      (first.pages.single as FakePage).pending.complete(null);
      await rendering;
      expect(first.disposals, 1);
      // Previously retained page references must use the new native generation.
      final next = page.render();
      await subscription.cancel();
      await document.dispose();
      expect(second.disposals, 0);
      (second.pages.single as FakePage).pending.complete(null);
      await next;
      expect(second.disposals, 1);
      await expectLater(page.render(), throwsStateError);
    },
  );
}

int addHandle(int handle, int value) => handle + value;

class HoldingBackend implements PdfrxEntryFunctions {
  final started = Completer<void>(), release = Completer<void>();
  @override
  Future<R> compute<M, R>(FutureOr<R> Function(M) callback, M message) async {
    started.complete();
    await release.future;
    return await callback(message);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
