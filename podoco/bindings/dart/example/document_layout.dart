import 'dart:convert';
import 'dart:io';

import 'package:podoco/podoco.dart';

class RawPages implements PageSource {
  @override
  final DocumentRef document;
  final Directory root;
  final List<Map<String, Object?>> entries;
  @override
  late final List<PageDescriptor> pages = List.unmodifiable(
    entries.map(
      (e) =>
          PageDescriptor.fromJson(Map<String, Object?>.from(e['page'] as Map)),
    ),
  );
  RawPages(this.root, Map<String, Object?> data)
    : document = DocumentRef.fromJson(
        Map<String, Object?>.from(data['document'] as Map),
      ),
      entries = List.unmodifiable(
        (data['pages'] as List).map((e) => Map<String, Object?>.from(e as Map)),
      );
  @override
  Future<PageInput> loadPage(PageRequest request) async {
    final index = pages.indexWhere((p) => p.key == request.page.key);
    final entry = entries[index];
    final file = File.fromUri(root.uri.resolve(entry['pixels'] as String));
    if (await file.length() > request.byteBudget) {
      throw const PodocoException(
        'limit_exceeded',
        'Raw file exceeds input reservation',
      );
    }
    final bytes = await file.readAsBytes();
    if (request.cancellation.isCancelled) {
      throw const PodocoException('cancelled', 'Render cancelled');
    }
    return PageInput(
      page: request.page,
      image: PageImage.copy(
        descriptor: ImageDescriptor.fromJson(
          Map<String, Object?>.from(entry['image'] as Map),
        ),
        bytes: bytes,
        byteBudget: request.byteBudget,
      ),
      pixelToPage: Affine.fromJson(entry['pixel_to_page']),
      renderProfile: entry['render_profile'] as String,
    );
  }
}

Future<void> main(List<String> args) async {
  FormulaBundle? formula;
  FormulaOptions? formulaOptions;
  var cacheBytes = 1;
  if (args.isNotEmpty && args.first == '--formula') {
    if (args.length < 4) {
      throw ArgumentError('--formula needs BUNDLE TOKEN_CAP CACHE_BYTES');
    }
    formula = await FormulaBundle.verify(args[1]);
    formulaOptions = FormulaOptions(maxNewTokens: int.parse(args[2]));
    cacheBytes = int.parse(args[3]);
    args = args.sublist(4);
  }
  if (args.length != 8) {
    throw ArgumentError(
      'usage: document_layout.dart [--formula FORMULA_BUNDLE TOKEN_CAP CACHE_BYTES] BUNDLE cpu|cpu-ne|all INPUT_BYTES TENSOR_BYTES RESULT_BYTES MAX_UPDATE_BYTES PENDING_UPDATES PAGES.json',
    );
  }
  final policy = switch (args[1]) {
    'cpu' => ComputePolicy.cpuOnly,
    'cpu-ne' => ComputePolicy.cpuAndNeuralEngine,
    'all' => ComputePolicy.all,
    _ => throw ArgumentError('Unknown compute policy'),
  };
  final file = File(args[7]);
  final source = RawPages(
    file.absolute.parent,
    Map<String, Object?>.from(jsonDecode(await file.readAsString()) as Map),
  );
  final bundle = await ModelBundle.verify(args[0]);
  final analyzer = await Analyzer.open(
    bundle,
    formulaBundle: formula,
    formulaOptions: formulaOptions,
    options: AnalyzerOptions(
      computePolicy: policy,
      limits: ResourceLimits(
        queuedJobs: 1,
        inputBytes: int.parse(args[2]),
        tensorBytes: int.parse(args[3]),
        resultBytes: int.parse(args[4]),
        maxUpdateBytes: int.parse(args[5]),
        pendingUpdates: int.parse(args[6]),
        decoderCacheBytes: cacheBytes,
      ),
    ),
  );
  try {
    final job = analyzer.analyzeDocument(
      pages: source,
      options: AnalysisOptions(
        profile: analyzer.profile,
        formulaScope: formula == null ? FormulaScope.none : FormulaScope.all,
      ),
      onUpdate: (update) async {
        stdout.writeln(jsonEncode(update.toJson()));
        await stdout.flush();
      },
    );
    final outcome = await job.done;
    stderr.writeln(
      '${outcome.status.name}: ${outcome.delivered.pagesFinished}/${outcome.summary.counts.pagesTotal} acknowledged pages',
    );
    await job.dispose();
    if (outcome.status != CompletionStatus.completed) exitCode = 1;
  } finally {
    await analyzer.dispose();
  }
}
