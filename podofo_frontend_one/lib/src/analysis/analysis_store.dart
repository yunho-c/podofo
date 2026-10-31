import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:podoco/podoco.dart' as podoco;
import 'package:synchronized/synchronized.dart';

import 'pdf_analysis_source.dart';
import 'analysis_snapshot.dart';

export 'analysis_snapshot.dart';

String analysisCacheKey(
  podoco.DocumentRef document,
  List<String> manifests,
  String profile,
  podoco.ComputePolicy computePolicy,
) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          2,
          document.toJson(),
          manifests,
          profile,
          computePolicy.name,
          layoutRenderProfile,
        ]),
      ),
    )
    .toString();

/// Derived page snapshots, bounded independently of the PDF and user database.
/// Writes stage asynchronously, then check the generation immediately before
/// a synchronous atomic rename. A late writer can never publish after that check.
class AnalysisStore {
  AnalysisStore(
    this.directory, {
    this.maxBytes = 64 * 1024 * 1024,
    this.maxPageBytes = 4 * 1024 * 1024,
  });
  final Directory directory;
  final int maxBytes, maxPageBytes;
  final _lock = Lock();

  File _file(String key, int pageIndex) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key) || pageIndex < 0) {
      throw ArgumentError('Invalid analysis cache identity');
    }
    return File(p.join(directory.path, '$key-$pageIndex.json'));
  }

  Future<AnalysisPageSnapshot?> read(
    String key,
    int pageIndex,
    podoco.DocumentRef document,
  ) => _lock.synchronized(() => _read(key, pageIndex, document));

  Future<AnalysisPageSnapshot?> _read(
    String key,
    int pageIndex,
    podoco.DocumentRef document,
  ) async {
    final file = _file(key, pageIndex);
    try {
      if (!await file.exists() || await file.length() > maxPageBytes) {
        return null;
      }
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (decoded['cache_version'] != 2 || decoded['key'] != key) return null;
      final snapshot = AnalysisPageSnapshot.fromJson(
        Map<String, Object?>.from(decoded['snapshot'] as Map),
      );
      if (snapshot.page.page.key.document != document ||
          snapshot.page.page.key.pageIndex != pageIndex ||
          !_matches(key, snapshot)) {
        return null;
      }
      return snapshot;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  bool _matches(String key, AnalysisPageSnapshot snapshot) {
    final page = snapshot.page;
    final pipeline = page.provenance.pipeline;
    return page.provenance.renderProfile == layoutRenderProfile &&
        analysisCacheKey(
              page.page.key.document,
              pipeline.models.map((m) => m.manifestSha256).toList(),
              pipeline.profile,
              pipeline.computePolicy,
            ) ==
            key;
  }

  Future<bool> write(
    String key,
    podoco.AnalysisUpdate update,
    bool Function() isCurrent,
  ) async => await apply(key, update, isCurrent) != null;

  /// Persist one accepted transition and return the derived snapshot. Formula
  /// updates merge only into the same analysis/page and never create fake SDK events.
  Future<AnalysisPageSnapshot?> apply(
    String key,
    podoco.AnalysisUpdate update,
    bool Function() isCurrent,
  ) => _lock.synchronized(() async {
    if (!isCurrent()) return null;
    final int index;
    if (update is podoco.FormulaFinished) {
      index = update.pageKey.pageIndex;
    } else {
      final page = pageOfUpdate(update);
      if (page == null) return null;
      index = page.page.key.pageIndex;
    }
    final previous = await _read(key, index, update.document);
    if (previous?.analysisId == update.analysisId &&
        update.sequence <= previous!.sequence) {
      return null;
    }
    final AnalysisPageSnapshot snapshot;
    if (update is podoco.FormulaFinished) {
      if (previous == null) {
        throw StateError('Formula update is missing its initial layout');
      }
      snapshot = previous.merge(update);
    } else {
      snapshot = AnalysisPageSnapshot.fromUpdate(update);
    }
    if (!_matches(key, snapshot)) {
      throw StateError('Unexpected cached analysis provenance');
    }
    final file = _file(key, index);
    final bytes = utf8.encode(
      jsonEncode({
        'cache_version': 2,
        'key': key,
        'snapshot': snapshot.toJson(),
      }),
    );
    if (bytes.length > maxPageBytes || bytes.length > maxBytes) {
      throw StateError('Analysis page exceeds cache budget');
    }
    await directory.create(recursive: true);
    final staging = await directory.createTemp('.write-');
    try {
      final temporary = File(p.join(staging.path, 'page'));
      await temporary.writeAsBytes(bytes, flush: true);
      if (!isCurrent()) return null;
      temporary.renameSync(file.path);
      await _prune();
      return isCurrent() ? snapshot : null;
    } finally {
      await staging.delete(recursive: true);
    }
  });

  Future<void> _prune() async {
    final files = <({File file, int bytes, DateTime modified})>[];
    var bytes = 0;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File ||
          !RegExp(r'^[0-9a-f]{64}-[0-9]+\.json$')
              .hasMatch(p.basename(entry.path))) {
        continue;
      }
      final stat = await entry.stat();
      bytes += stat.size;
      files.add((file: entry, bytes: stat.size, modified: stat.modified));
    }
    files.sort((a, b) => a.modified.compareTo(b.modified));
    for (final file in files) {
      if (bytes <= maxBytes) break;
      await file.file.delete();
      bytes -= file.bytes;
    }
  }
}

podoco.PageAnalysis? pageOfUpdate(podoco.AnalysisUpdate update) =>
    switch (update) {
      podoco.PageLayoutReady(:final page) => page,
      podoco.PageFinished(:final page) => page,
      _ => null,
    };
