import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/dark_mode/photo_analysis.dart';
import 'package:podofo_one/src/dark_mode/photo_overrides.dart';
import 'package:podofo_one/src/dark_mode/photo_diagnostics.dart';
import 'package:podofo_one/src/services/photo_override_store.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/providers/document_provider.dart';

class _MemoryStore implements PhotoOverrideStore {
  final records = <String, Map<String, bool>>{};
  bool fail = false;
  @override
  Map<String, bool> load(String hash) => Map.of(records[hash] ?? {});
  @override
  void save(String hash, Map<String, bool> decisions) {
    if (fail) throw StateError('Disk unavailable');
    records[hash] = Map.of(decisions);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'diagnostics retain automatic reasons and report effective manual choices',
    () {
      const candidate = PhotoCandidate(
        2,
        'limited-palette',
        region: PhotoRegion(0, 0, 100, 100),
      );
      PhotoDiagnosticEntry entry(
        bool override, {
        String inactive = 'mask-pending',
      }) => PhotoDiagnosticEntry(
        pageNumber: 1,
        candidate: candidate,
        rect: const Rect.fromLTRB(0, 0, 1, 1),
        preserved: override,
        inactiveReason: inactive,
        override: override,
      );
      expect(entry(true).reason, 'user-preserved');
      expect(entry(true).status, PhotoDiagnosticStatus.preserved);
      expect(entry(false).reason, 'user-inverted');
      expect(entry(false, inactive: 'inversion-off').reason, 'inversion-off');
      expect(candidate.reason, 'limited-palette');
    },
  );
  test(
    'explicit choices persist, reset to automatic, and report write failures',
    () {
      final store = _MemoryStore();
      final choices = PhotoOverrides('document', store: store);
      expect(choices.toggle('photo', automatic: true), isTrue);
      expect(choices.decision('photo'), false);
      final restored = PhotoOverrides('document', store: store);
      expect(restored.decision('photo'), false);
      restored.dispose();
      store.fail = true;
      expect(choices.toggle('photo', automatic: true), isFalse);
      expect(choices.decision('photo'), false);
      expect(choices.error, isNotNull);
      store.fail = false;
      // Even if the classifier changes, the next click removes the explicit choice.
      expect(choices.toggle('photo', automatic: false), isTrue);
      expect(choices.decision('photo'), isNull);
      expect(choices.error, isNull);
      expect(choices.toggle('plot', automatic: false), isTrue);
      expect(choices.decision('plot'), true);
      store.fail = true;
      expect(choices.documentSaved('saved-document'), isFalse);
      expect(choices.decision('plot'), true);
      expect(choices.error, contains('PDF saved'));
      choices.dispose();
    },
  );

  test('database choices survive reopen, move, annotation save and Save As', () async {
    final dir = Directory.systemTemp.createTempSync('podofo-photo-overrides-');
    var store = Store(getObjectBoxModel(), directory: '${dir.path}/db');
    final source = File('test/fixtures/photo_dark_mode/mixed.pdf')
        .readAsBytesSync();
    final path = '${dir.path}/paper.pdf';
    File(path).writeAsBytesSync(source);
    await pdfrxInitialize();
    PdfSession? session;
    Future<PhotoPageAnalysis> analyze() =>
        session!.readLocked((pdf) => analyzePhotos(pdf, 1));
    try {
      session = await PdfSession.open(
        path,
        photoOverrideStore: StoredPhotoOverrides(store),
      );
      var result = await analyze();
      final photo = result.candidates.firstWhere(
        (c) => c.reason == 'likely-photo',
      );
      final plot = result.candidates.firstWhere(
        (c) => c.classification != null && c.reason != 'likely-photo',
      );
      final page = session.lease.document.pages.first;
      final photoKey = PhotoOverrides.target(page, photo)!;
      final plotKey = PhotoOverrides.target(page, plot)!;
      expect(session.photoOverrides.toggle(photoKey, automatic: true), isTrue);
      expect(session.photoOverrides.toggle(plotKey, automatic: false), isTrue);
      expect(session.dirty, isFalse);
      expect(File(path).readAsBytesSync(), source);

      // Object enumeration can change without changing the panel's identity.
      final renumbered = PhotoCandidate(
        999,
        photo.reason,
        region: photo.region,
        classification: photo.classification,
        sampleHash: photo.sampleHash,
        objectPath: [999, 3],
      );
      expect(PhotoOverrides.target(page, renumbered), photoKey);
      final changed = PhotoCandidate(
        999,
        photo.reason,
        region: photo.region,
        classification: photo.classification,
        sampleHash: 'different-pixels',
      );
      expect(PhotoOverrides.target(page, changed), isNot(photoKey));
      for (final c in result.candidates.where(
        (c) => c.classification == null,
      )) {
        expect(PhotoOverrides.target(page, c), isNull);
      }

      await session.close();
      store.close();
      store = Store(getObjectBoxModel(), directory: '${dir.path}/db');
      final moved = '${dir.path}/renamed.pdf';
      File(path).renameSync(moved);
      session = await PdfSession.open(
        moved,
        photoOverrideStore: StoredPhotoOverrides(store),
      );
      expect(session.photoOverrides.decision(photoKey), false);
      expect(session.photoOverrides.decision(plotKey), true);
      await session.highlight([
        const HighlightRegion(1, [PdfRect(35, 45, 80, 30)]),
      ], 0x88ffeb3b);
      result = await analyze();
      expect(
        PhotoOverrides.target(
          session.lease.document.pages.first,
          result.candidates.firstWhere((c) => c.reason == 'likely-photo'),
        ),
        photoKey,
      );
      expect(session.photoOverrides.decision(photoKey), false);
      await session.save();
      final copied = '${dir.path}/saved-copy.pdf';
      await session.save(destination: copied);
      await session.close();
      for (final file in [moved, copied]) {
        session = await PdfSession.open(
          file,
          photoOverrideStore: StoredPhotoOverrides(store),
        );
        result = await analyze();
        final reopenedKey = PhotoOverrides.target(
          session.lease.document.pages.first,
          result.candidates.firstWhere((c) => c.reason == 'likely-photo'),
        )!;
        expect(reopenedKey, photoKey);
        expect(session.photoOverrides.decision(reopenedKey), false);
        expect(session.photoOverrides.decision(plotKey), true);
        await session.close();
      }
      // Replacing the file externally never applies choices by pathname alone.
      File(copied).writeAsBytesSync(
        File('test/fixtures/photo_dark_mode/forms.pdf').readAsBytesSync(),
      );
      session = await PdfSession.open(
        copied,
        photoOverrideStore: StoredPhotoOverrides(store),
      );
      expect(session.photoOverrides.count, 0);
    } finally {
      await session?.close(discard: true);
      await PdfrxEntryFunctions.instance.stopBackgroundWorker();
      store.close();
      dir.deleteSync(recursive: true);
    }
  });

  test('app shutdown and document restoration retain choices without double disposal', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('podofo-photo-restore-');
    final store = Store(getObjectBoxModel(), directory: '${dir.path}/db');
    final path = '${dir.path}/paper.pdf';
    File('test/fixtures/photo_dark_mode/mixed.pdf').copySync(path);
    ProviderContainer createContainer() => ProviderContainer(
      overrides: [objectboxProvider.overrideWithValue(ObjectBox(store))],
    );
    var container = createContainer();
    await pdfrxInitialize();
    try {
      expect(
        await container
            .read(loadedDocumentsProvider.notifier)
            .addDocument(path),
        isTrue,
      );
      var session = container
          .read(loadedDocumentsProvider)
          .values
          .single
          .session;
      final analysis = await session.readLocked((pdf) => analyzePhotos(pdf, 1));
      final target = PhotoOverrides.target(
        session.lease.document.pages.first,
        analysis.candidates.firstWhere((c) => c.reason == 'likely-photo'),
      )!;
      session.photoOverrides.toggle(target, automatic: true);
      // DesktopLifecycle closes sessions before the provider tree is disposed.
      await session.close();
      container.dispose();
      container = createContainer();
      await container.read(loadedDocumentsProvider.notifier).restore();
      session = container.read(loadedDocumentsProvider).values.single.session;
      expect(session.photoOverrides.decision(target), false);
      expect(session.dirty, isFalse);
      await session.close();
    } finally {
      container.dispose();
      await PdfrxEntryFunctions.instance.stopBackgroundWorker();
      store.close();
      dir.deleteSync(recursive: true);
    }
  });
}
