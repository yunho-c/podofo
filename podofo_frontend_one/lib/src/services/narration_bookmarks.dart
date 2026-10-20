import '../../objectbox.g.dart';
import '../data/narration_bookmark.dart';
import '../narration/source_map.dart';

class NarrationBookmarks {
  NarrationBookmarks(this.store);
  final Store store;
  NarrationBookmark? find(String path) {
    final query = store
        .box<NarrationBookmark>()
        .query(NarrationBookmark_.filePath.equals(path))
        .build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  void save(String path, SourceAnchor anchor) {
    final prior = find(path);
    store.box<NarrationBookmark>().put(
      NarrationBookmark(
        id: prior?.id ?? 0,
        filePath: path,
        page: anchor.page,
        offset: anchor.offset,
        textHash: anchor.textHash,
      ),
    );
  }

  void copy(String oldPath, String newPath) {
    final bookmark = find(oldPath);
    if (bookmark != null) save(newPath, bookmark.anchor);
  }
}
