import 'dart:convert';

import '../../objectbox.g.dart';
import '../dark_mode/photo_overrides.dart';
import '../data/photo_override_entity.dart';

class StoredPhotoOverrides implements PhotoOverrideStore {
  StoredPhotoOverrides(this.store);
  final Store store;

  PhotoOverrideEntity? _find(String hash) {
    final query = store
        .box<PhotoOverrideEntity>()
        .query(PhotoOverrideEntity_.documentHash.equals(hash))
        .build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  @override
  Map<String, bool> load(String documentHash) {
    final record = _find(documentHash);
    if (record == null) return {};
    try {
      final decoded = jsonDecode(record.decisions);
      if (decoded is! Map<String, dynamic>) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is bool) entry.key: entry.value as bool,
      };
    } on FormatException {
      return {};
    }
  }

  @override
  void save(String documentHash, Map<String, bool> decisions) {
    store.runInTransaction(TxMode.write, () {
      final prior = _find(documentHash);
      final box = store.box<PhotoOverrideEntity>();
      if (decisions.isEmpty) {
        if (prior != null) box.remove(prior.id);
      } else {
        box.put(
          PhotoOverrideEntity(
            id: prior?.id ?? 0,
            documentHash: documentHash,
            decisions: jsonEncode(decisions),
          ),
        );
      }
    });
  }
}
