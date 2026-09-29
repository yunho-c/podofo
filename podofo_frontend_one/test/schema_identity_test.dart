import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('regeneration preserves every legacy entity and property UID', () {
    final legacy = jsonDecode(
      File('test/fixtures/legacy_objectbox_model.json').readAsStringSync(),
    ) as Map;
    final current =
        jsonDecode(File('lib/objectbox-model.json').readAsStringSync()) as Map;
    for (final oldEntity in legacy['entities'] as List) {
      final entity = (current['entities'] as List).singleWhere(
        (dynamic entry) => entry['id'] == oldEntity['id'],
      );
      for (final oldProperty in oldEntity['properties'] as List) {
        final property = (entity['properties'] as List).singleWhere(
          (dynamic entry) => entry['id'] == oldProperty['id'],
        );
        expect(property['type'], oldProperty['type']);
        expect(
          property['name'],
          oldProperty['name'] == 'enableAutoSave'
              ? 'autoSaveEnabled'
              : oldProperty['name'],
        );
      }
    }
  });
}
