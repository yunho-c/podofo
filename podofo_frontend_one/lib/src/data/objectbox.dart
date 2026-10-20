import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:podofo_one/objectbox.g.dart';

import 'thumbnail_entity.dart';

class ObjectBox {
  late final Store store;

  ObjectBox(this.store);

  static Future<ObjectBox> create() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dbDir = Directory(p.join(docsDir.path, "obx-docs"));

    final store = await openStore(
      directory: dbDir.path,
      // Sandboxed macOS requires an entitled prefix for ObjectBox's semaphores.
      // Keep this in sync with macos/Runner/*.entitlements (19 characters max).
      macosApplicationGroup: Platform.isMacOS ? 'group.podofo' : null,
    );
    // Legacy thumbnails were keyed only by path and have no reliable freshness.
    // They are derived data; the new bounded in-memory cache regenerates on demand.
    store.box<ThumbnailEntity>().removeAll();
    return ObjectBox(store);
  }
}
