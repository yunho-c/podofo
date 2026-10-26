import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:podoco/podoco.dart' as podoco;
import 'package:synchronized/synchronized.dart';

import 'pdf_analysis_source.dart';

String analysisCacheKey(
  podoco.DocumentRef document,
  String manifest,
  String profile,
) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          1,
          document.toJson(),
          manifest,
          profile,
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
    this.maxPageBytes = 256 * 1024,
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

  Future<podoco.AnalysisUpdate?> read(
    String key,
    int pageIndex,
    podoco.DocumentRef document,
  ) => _lock.synchronized(() async {
    final file = _file(key, pageIndex);
    try {
      if (!await file.exists() || await file.length() > maxPageBytes) {
        return null;
      }
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (decoded['cache_version'] != 1 || decoded['key'] != key) return null;
      final update = podoco.AnalysisUpdate.fromJson(
        Map<String, Object?>.from(decoded['update'] as Map),
      );
      final page = pageOfUpdate(update);
      if (page == null ||
          page.page.key.document != document ||
          page.page.key.pageIndex != pageIndex ||
          page.provenance.renderProfile != layoutRenderProfile ||
          analysisCacheKey(
                document,
                page.provenance.pipeline.models.first.manifestSha256,
                page.provenance.pipeline.profile,
              ) !=
              key) {
        return null;
      }
      return update;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  });

  Future<bool> write(
    String key,
    podoco.AnalysisUpdate update,
    bool Function() isCurrent,
  ) => _lock.synchronized(() async {
    final page = pageOfUpdate(update);
    if (page == null || !isCurrent()) return false;
    final file = _file(key, page.page.key.pageIndex);
    final bytes = utf8.encode(
      jsonEncode({'cache_version': 1, 'key': key, 'update': update.toJson()}),
    );
    if (bytes.length > maxPageBytes || bytes.length > maxBytes) {
      throw StateError('Analysis page exceeds cache budget');
    }
    await directory.create(recursive: true);
    final staging = await directory.createTemp('.write-');
    try {
      final temporary = File(p.join(staging.path, 'page'));
      await temporary.writeAsBytes(bytes, flush: true);
      if (!isCurrent()) return false;
      temporary.renameSync(file.path);
      await _prune();
      return isCurrent();
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
