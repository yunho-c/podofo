import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/data/document_entity.dart';
import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/services/document_file_access.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/pdf_fixture.dart';
import 'support/file_access_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late File pdf;
  final calls = <MethodCall>[];

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('podofo-file-access-');
    await pdfrxInitialize(tmpPath: temporary.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temporary.delete(recursive: true);
  });
  setUp(() async {
    pdf = File('${temporary.path}/document.pdf');
    await pdf.writeAsBytes(pdfFixture());
    calls.clear();
    installFileAccessMock((call) async {
      calls.add(call);
      if (call.method == 'acquire') {
        return {'path': pdf.path, 'token': 'access-token'};
      }
      return ordinaryFileAccess(call);
    });
  });

  test('restore reads resolved bookmark path and releases access', () async {
    final session = await PdfSession.open('${temporary.path}/old-path.pdf');
    expect(session.path, await pdf.resolveSymbolicLinks());
    expect(calls.map((c) => c.method), ['acquire', 'release']);
    expect((calls.first.arguments as Map)['selected'], false);
    await session.close();
    // The PDF's detached data remains valid after releasing the file grant.
  }, skip: !Platform.isMacOS);

  test(
    'picker grants are captured before reading; failed decode releases',
    () async {
      await pdf.writeAsString('not a PDF');
      await expectLater(
        PdfSession.open(pdf.path, selected: true),
        throwsA(anything),
      );
      expect((calls.first.arguments as Map)['selected'], true);
      expect(calls.map((c) => c.method), ['acquire', 'release']);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'release is idempotent and missing bridge is not silently ignored',
    () async {
      final access = await DocumentFileAccess.acquire(pdf.path);
      await access.release();
      await access.release();
      expect(calls.where((c) => c.method == 'release'), hasLength(1));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DocumentFileAccess.channel, null);
      await expectLater(
        DocumentFileAccess.acquire(pdf.path),
        throwsA(isA<MissingPluginException>()),
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'save reacquires access and refreshes replacement bookmark before release',
    () async {
      final session = await PdfSession.open(pdf.path);
      await session.highlight([
        const HighlightRegion(1, [PdfRect(30, 280, 90, 260)]),
      ], 0x88ffff00);
      calls.clear();
      await session.save();
      expect(calls.map((c) => c.method), [
        'acquire',
        'stagingDirectory',
        'remember',
        'release',
      ]);
      expect(session.dirty, false);
      expect(session.fileAccessWarning, isNull);
      await session.close();
    },
    skip: !Platform.isMacOS,
  );

  test('conflicting save releases access and keeps edits dirty', () async {
    final session = await PdfSession.open(pdf.path);
    await session.highlight([
      const HighlightRegion(1, [PdfRect(30, 280, 90, 260)]),
    ], 0x88ffff00);
    await pdf.writeAsString('external change');
    calls.clear();
    await expectLater(session.save(), throwsStateError);
    expect(calls.map((c) => c.method), ['acquire', 'release']);
    expect(session.dirty, true);
    expect(await pdf.readAsString(), 'external change');
    await session.close(discard: true);
  }, skip: !Platform.isMacOS);

  test('Save As uses selected destination and reports bookmark failure as a saved-file warning', () async {
    final session = await PdfSession.open(pdf.path);
    final copy = File('${temporary.path}/copy.pdf');
    calls.clear();
    installFileAccessMock((call) async {
      calls.add(call);
      if (call.method == 'remember') {
        throw PlatformException(code: 'file_access', message: 'cannot persist');
      }
      return ordinaryFileAccess(call);
    });
    await session.save(destination: copy.path);
    expect(await copy.readAsBytes(), pdfFixture());
    expect(session.path, copy.path);
    expect(session.dirty, false);
    expect(session.fileAccessWarning, contains('PDF saved'));
    expect(calls.map((c) => c.method), ['stagingDirectory', 'remember']);
    await session.close();
  }, skip: !Platform.isMacOS);

  test(
    'legacy denied entry recovers its last page, including symlink selection',
    () async {
      final path = await pdf.resolveSymbolicLinks();
      final link = Link('${temporary.path}/selected-link.pdf');
      await link.create(path);
      final store = Store(
        getObjectBoxModel(),
        directory: '${temporary.path}/db',
      );
      store.box<DocumentEntity>().put(
        DocumentEntity(filePath: path, lastOpenedPage: 3),
      );
      final container = ProviderContainer(
        overrides: [objectboxProvider.overrideWithValue(ObjectBox(store))],
      );
      installFileAccessMock((call) async {
        calls.add(call);
        if (call.method == 'acquire') {
          if ((call.arguments as Map)['selected'] != true) {
            throw PlatformException(code: 'file_access', message: 'denied');
          }
          return {'path': path, 'token': 'recovered'};
        }
        return ordinaryFileAccess(call);
      });
      try {
        expect(await container.read(initialDocumentsProvider.future), isEmpty);
        final notifier = container.read(loadedDocumentsProvider.notifier);
        expect(await notifier.addDocument(path), false);
        expect(store.box<DocumentEntity>().getAll().single.lastOpenedPage, 3);
        expect(await notifier.recoverDocument(path, link.path), true);
        expect(container.read(documentFailuresProvider), isEmpty);
        expect(
          container.read(loadedDocumentsProvider).values.single.lastOpenedPage,
          3,
        );
        expect(store.box<DocumentEntity>().getAll().single.filePath, path);
        expect(store.box<DocumentEntity>().getAll().single.lastOpenedPage, 3);
      } finally {
        container.dispose();
        store.close();
      }
    },
    skip: !Platform.isMacOS,
  );
}
