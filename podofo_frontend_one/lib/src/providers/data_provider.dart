import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:podofo_one/src/data/objectbox.dart';

final objectboxProvider = Provider<ObjectBox>(
  (ref) => throw StateError(
    'ObjectBox must be initialized before starting the app.',
  ),
);
