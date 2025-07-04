import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:podofo_one/objectbox.g.dart';

class ObjectBox {
  late final Store store;

  ObjectBox._create(this.store);

  static Future<ObjectBox> create() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dbDir = Directory(p.join(docsDir.path, "obx-docs"));

    // // DEBUG: Deletes the database directory on startup.
    // // NOTE: Remove this block for production release.
    // if (dbDir.existsSync()) {
    //   dbDir.deleteSync(recursive: true);
    // }

    final store = await openStore(directory: dbDir.path);
    return ObjectBox._create(store);
  }
}
