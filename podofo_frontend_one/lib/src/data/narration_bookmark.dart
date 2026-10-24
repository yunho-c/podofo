import 'package:objectbox/objectbox.dart';

import '../narration/source_map.dart';
import '../narration/paper_plan.dart';

@Entity()
class NarrationBookmark {
  NarrationBookmark({
    this.id = 0,
    required this.filePath,
    required this.page,
    required this.offset,
    required this.textHash,
    this.mappingVersion = 1,
    this.planVersion = PaperPlanner.version,
    this.contextBefore = '',
    this.contextAfter = '',
  });
  @Id()
  int id;
  @Unique()
  String filePath;
  int page, offset, mappingVersion, planVersion;
  String textHash, contextBefore, contextAfter;
  SourceAnchor get anchor => SourceAnchor(
    page,
    offset,
    textHash,
    contextBefore: contextBefore,
    contextAfter: contextAfter,
  );
}
