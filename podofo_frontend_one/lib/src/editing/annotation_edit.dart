/// Editor values use unrotated PDF coordinates relative to the page's bounding
/// box. Native dictionaries/resources are preserved separately by the adapter.
class AnnotationRecord {
  AnnotationRecord({
    required this.id,
    required this.pageNumber,
    required this.index,
    required this.contents,
    required this.author,
    required this.pdfName,
    required this.flags,
    required this.argb,
    required this.hasAppearance,
    required Iterable<List<double>> quads,
    List<double>? bounds,
    this.created = '',
    this.modified = '',
    this.subject = '',
  }) : bounds = List<double>.unmodifiable(bounds ?? const []),
       quads = List.unmodifiable(
         quads.map((q) => List<double>.unmodifiable(q)),
       );

  final String id;
  final int pageNumber;
  // Adapter locator within this state, never the application's identity.
  final int index;
  final String contents, author, pdfName;
  final int flags;
  final int? argb;
  final bool hasAppearance;
  final List<List<double>> quads;
  bool get locked => flags & (64 | 128 | 512) != 0;
  final List<double> bounds;
  final String created, modified, subject;
  bool get owned => author == 'PoDoFo';
  bool get canEdit =>
      owned &&
      !locked &&
      argb != null &&
      quads.isNotEmpty &&
      bounds.length == 4 &&
      bounds.every((n) => n.isFinite) &&
      bounds[2] > bounds[0] &&
      bounds[1] > bounds[3] &&
      quads.every((q) => q.length == 8 && q.every((n) => n.isFinite));
  bool get canRecolor => canEdit;
  int get retainedBytes =>
      320 +
      8 * bounds.length +
      64 * quads.length +
      2 *
          (id.length +
              contents.length +
              author.length +
              pdfName.length +
              created.length +
              modified.length +
              subject.length);

  AnnotationRecord copyWith({int? argb, int? index}) => AnnotationRecord(
    id: id,
    pageNumber: pageNumber,
    index: index ?? this.index,
    contents: contents,
    author: author,
    pdfName: pdfName,
    flags: flags,
    argb: argb ?? this.argb,
    hasAppearance: argb == null ? hasAppearance : false,
    quads: quads,
    bounds: bounds,
    created: created,
    modified: modified,
    subject: subject,
  );
}

class AnnotationChange {
  const AnnotationChange({required this.id, this.before, this.after});
  final String id;
  final AnnotationRecord? before, after;
}

class AnnotationEdit {
  AnnotationEdit({
    required this.label,
    required Iterable<AnnotationChange> changes,
  }) : changes = List.unmodifiable(changes) {
    final seen = <String>{};
    for (final change in this.changes) {
      if (!seen.add(change.id) ||
          (change.before == null && change.after == null) ||
          (change.before != null && change.before!.id != change.id) ||
          (change.after != null && change.after!.id != change.id)) {
        throw ArgumentError('Invalid annotation change.');
      }
    }
    if (this.changes.isEmpty) throw ArgumentError('Empty edit.');
  }
  final String label;
  final List<AnnotationChange> changes;
  Set<int> get affectedPages => {
    for (final change in changes) ...[
      if (change.before != null) change.before!.pageNumber,
      if (change.after != null) change.after!.pageNumber,
    ],
  };
}
