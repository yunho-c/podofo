import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/data/pdf_document_lease.dart';

class _FakeDocument implements PdfDocument {
  int disposals = 0;
  @override
  String get sourceName => 'fake.pdf';
  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'closing session waits for viewer and in-flight work before disposing',
    () async {
      final native = _FakeDocument();
      final lease = PdfDocumentLease(native);
      final viewer = lease.reference.resolveListenable();
      final detachViewer = viewer.addListener(() {});
      final unblock = Completer<void>();
      final work = lease.use((_) => unblock.future);
      lease.close();
      lease.close();
      expect(native.disposals, 0);
      detachViewer();
      expect(native.disposals, 0);
      unblock.complete();
      await work;
      expect(native.disposals, 1);
      await expectLater(lease.use((_) => 1), throwsStateError);
    },
  );

  test('reopening a document creates an independent lifetime', () async {
    final first = _FakeDocument();
    final second = _FakeDocument();
    final firstLease = PdfDocumentLease(first);
    final secondLease = PdfDocumentLease(second);
    firstLease.close();
    expect(first.disposals, 1);
    expect(second.disposals, 0);
    secondLease.close();
    expect(second.disposals, 1);
  });
}
