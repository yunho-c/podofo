import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import 'photo_analysis.dart';

abstract interface class PhotoOverrideStore {
  Map<String, bool> load(String documentHash);
  void save(String documentHash, Map<String, bool> decisions);
}

/// One document's explicit choices, independent of the disposable analysis LRU.
/// Values are the chosen result, not a permanent inversion of the classifier.
class PhotoOverrides extends ChangeNotifier {
  PhotoOverrides(String documentHash, {PhotoOverrideStore? store})
    : _documentHash = documentHash,
      _store = store,
      _decisions = store?.load(documentHash) ?? {};

  String _documentHash;
  final PhotoOverrideStore? _store;
  Map<String, bool> _decisions;
  String? error;
  int get count => _decisions.length;

  /// Only classified images have passed all geometry and opacity checks. Match
  /// their sampled pixels and page-space placement, never a mutable object index.
  static String? target(PdfPage page, PhotoCandidate candidate) {
    if (candidate.classification == null || candidate.sampleHash == null) {
      return null;
    }
    final r = candidate.region;
    return jsonEncode([
      1, // Anchor format, independent of classifier thresholds.
      page.pageNumber,
      page.rotation.index,
      for (final v in [
        page.width,
        page.height,
        r.left,
        r.bottom,
        r.right,
        r.top,
      ])
        v.toStringAsFixed(3),
      candidate.sampleHash,
    ]);
  }

  bool? decision(String? target) => target == null ? null : _decisions[target];

  /// A second click removes the override and returns to today's automatic result.
  bool toggle(String target, {required bool automatic}) {
    final next = Map<String, bool>.from(_decisions);
    if (next.containsKey(target)) {
      next.remove(target);
    } else {
      next[target] = !automatic;
    }
    try {
      _store?.save(_documentHash, next);
      _decisions = next;
      error = null;
    } catch (_) {
      error = 'Could not save the photo preference. Try again.';
      notifyListeners();
      return false;
    }
    notifyListeners();
    return true;
  }

  /// A known app save carries choices to the new bytes. External changes get a
  /// different hash on open and cannot inherit stale decisions by pathname.
  bool documentSaved(String documentHash) {
    if (_documentHash == documentHash) return true;
    _documentHash = documentHash;
    try {
      _store?.save(documentHash, _decisions);
      error = null;
    } catch (_) {
      error = 'PDF saved, but its photo preferences could not be saved.';
      notifyListeners();
      return false;
    }
    return true;
  }
}
