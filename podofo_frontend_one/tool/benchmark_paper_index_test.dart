// Explicit local diagnostic; no downloads, synthesis, or input mutations.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('measure a local document index and verify preview parity', () async {
    final input = Platform.environment['PODOFO_PDF'];
    final output = Platform.environment['PODOFO_INDEX_OUTPUT'];
    if (input == null || output == null) {
      fail('Set PODOFO_PDF and PODOFO_INDEX_OUTPUT (a new JSON file).');
    }
    final destination = File(output);
    if (await destination.exists()) fail('Output already exists: $output');
    final temporary = await Directory.systemTemp.createTemp('podofo-index-');
    Pdfrx.pdfiumModulePath = Platform.environment['PDFIUM_PATH'];
    await pdfrxInitialize(tmpPath: temporary.path);
    final session = await PdfSession.open(input);
    const options = PaperReadOptions();
    final sequence = PaperSequence(session, options);
    try {
      final startPage = int.parse(
        Platform.environment['PODOFO_INDEX_START'] ?? '1',
      );
      final first = Stopwatch()..start();
      await sequence.start(page: startPage);
      first.stop();
      final scan = Stopwatch()..start();
      await Future.wait([sequence.prepareNext(), sequence.indexDocument()]);
      scan.stop();
      final snapshot = sequence.index.snapshot;
      final extractionCount = sequence.planner.extractionCount;
      final cacheCount = sequence.cachedPageCount;
      final metadata = [
        for (final page in snapshot.pages)
          {
            'page': page.page,
            'status': page.status.name,
            'text_hash': page.textHash,
            'issue': page.issue,
            'ends_paper': page.endsPaper,
            'passages': [
              for (final p in page.passages)
                {
                  'revision': p.revision,
                  'options': p.optionsKey,
                  'ordinal': p.ordinal,
                  'anchor': [p.page, p.anchor.offset, p.anchor.textHash],
                  'spoken_hash': p.spokenTextHash,
                  'utf16': p.utf16Length,
                  'scalars': p.scalarCount,
                  'words': p.wordCount,
                  'punctuation': p.punctuationCount,
                },
            ],
          },
      ];
      // Parity verification is outside the timed scan and extraction count.
      for (final indexed in snapshot.pages) {
        final plan = await sequence.preview(indexed.page);
        expect(indexed.issue, plan.issue);
        expect(indexed.textHash, plan.page.textHash);
        expect(indexed.endsPaper, plan.endsPaper);
        expect(indexed.passages, hasLength(plan.passages.length));
        for (var i = 0; i < plan.passages.length; i++) {
          final passage = plan.passages[i], descriptor = indexed.passages[i];
          expect(descriptor.ordinal, i);
          expect(descriptor.anchor.offset, passage.anchorAt(0)!.offset);
          expect(descriptor.utf16Length, passage.text.length);
          expect(
            descriptor.spokenTextHash,
            sha256.convert(utf8.encode(passage.text)).toString(),
          );
        }
      }
      expect(sequence.pageNumber, startPage);
      expect(cacheCount, lessThanOrEqualTo(2));
      expect(sequence.planner.peakExtractions, 1);
      final report = {
        'input': File(input).absolute.path,
        'input_sha256': (await sha256.bind(File(input).openRead()).first)
            .toString(),
        'options': options.key,
        'start_page': startPage,
        'seed_plan_ms': first.elapsedMicroseconds / 1000,
        'scan_with_prefetch_ms': scan.elapsedMicroseconds / 1000,
        'page_count': snapshot.pageCount,
        'scope_end_page': snapshot.scopeEndPage,
        'processed_pages': snapshot.processedPageCount,
        'passage_count': snapshot.readablePassageCount,
        'unresolved_pages': snapshot.unresolvedPages
            .map((p) => p.page)
            .toList(),
        'fully_resolved': snapshot.fullyResolved,
        'detailed_cache_pages': cacheCount,
        'extractions_including_seed': extractionCount,
        'peak_concurrent_extractions': sequence.planner.peakExtractions,
        'yielded_plans': sequence.planner.yieldedPlans,
        // Serialized metadata including field names; not heap/RSS accounting.
        'metadata_json_bytes': utf8.encode(jsonEncode(metadata)).length,
        'preview_parity': true,
        'pages': metadata,
      };
      await destination.parent.create(recursive: true);
      await destination.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
    } finally {
      sequence.close();
      await session.close();
      await PdfrxEntryFunctions.instance.stopBackgroundWorker();
      await temporary.delete(recursive: true);
    }
  });
}
