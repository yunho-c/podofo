import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:podoco/podoco.dart' as podoco;

import '../previews/link_target.dart';
import 'analysis_store.dart';
import 'analysis_coordinator.dart';
import 'pdf_analysis_source.dart';

class PreviewAnalysisIdentity {
  PreviewAnalysisIdentity(
    this.document,
    List<String> manifests,
    this.profile,
    this.computePolicy,
  ) : manifests = List.unmodifiable(manifests);
  final podoco.DocumentRef document;
  final List<String> manifests;
  final String profile;
  final podoco.ComputePolicy computePolicy;
  String get key =>
      analysisCacheKey(document, manifests, profile, computePolicy);
}

/// Retains the complete provenance, including model artifacts and raster policy.
/// Formula completion is independent from layout readiness.
class PreviewLayoutEvidence {
  PreviewLayoutEvidence(AnalysisPageSnapshot snapshot)
    : analysisId = snapshot.analysisId,
      sequence = snapshot.sequence,
      page = snapshot.page,
      identity = sha256
          .convert(utf8.encode(jsonEncode(snapshot.toJson())))
          .toString();
  final String analysisId, identity;
  final int sequence;
  final podoco.PageAnalysis page;
  bool get layoutReady => true;
}

/// Offscreen access through a read-only cache or the shared on-demand lane.
/// Neither path selects a visible analysis page or notifies its controller.
class PreviewLayoutRepository {
  const PreviewLayoutRepository(this.store, this.identity) : coordinator = null;
  const PreviewLayoutRepository.onDemand(this.coordinator)
    : store = null,
      identity = null;
  final AnalysisStore? store;
  final PreviewAnalysisIdentity? identity;
  final AnalysisCoordinator? coordinator;
  Future<PreviewLayoutEvidence?> read(
    LinkPreviewRequest request, {
    required bool Function() isCurrent,
    PreviewCancellation? cancellation,
  }) async {
    final shared = coordinator;
    if (shared != null) {
      if (!request.isCurrent ||
          !isCurrent() ||
          cancellation?.isCancelled == true) {
        return null;
      }
      final ticket = shared.request(request, isCurrent);
      final remove = cancellation?.onCancel(ticket.cancel);
      try {
        final snapshot = await ticket.result;
        return snapshot != null && request.isCurrent && isCurrent()
            ? PreviewLayoutEvidence(snapshot)
            : null;
      } finally {
        remove?.call();
        ticket.cancel();
      }
    }
    final identity = this.identity!;
    if (!request.isCurrent ||
        !isCurrent() ||
        analysisDocumentRef(request.session) != identity.document) {
      return null;
    }
    final snapshot = await store!.read(
      identity.key,
      request.destination.pageNumber - 1,
      identity.document,
    );
    if (!request.isCurrent ||
        !isCurrent() ||
        snapshot == null ||
        analysisDocumentRef(request.session) != identity.document) {
      return null;
    }
    return PreviewLayoutEvidence(snapshot);
  }
}
