import 'package:objectbox/objectbox.dart';

import '../narration/source_map.dart';

@Entity()
class NarrationBookmark {
  NarrationBookmark({
    this.id = 0,
    required this.filePath,
    required this.page,
    required this.offset,
    required this.textHash,
    this.mappingVersion = 1,
  });
  @Id()
  int id;
  @Unique()
  String filePath;
  int page, offset, mappingVersion;
  String textHash;
  SourceAnchor get anchor => SourceAnchor(page, offset, textHash);
}
