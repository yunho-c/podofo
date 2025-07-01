import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/providers/providers.dart';

/// TODO: Implement as a more efficient way to pass around loadedDocuments
///       information to tab builder; title, index, previewThumbnail
final tabsProvider = Provider<List<Document>>((ref) {
  final documents = ref.watch(loadedDocumentsProvider);
  return documents.values.toList();
});

final currentTabIndexProvider = StateProvider<int>((ref) => 0);
