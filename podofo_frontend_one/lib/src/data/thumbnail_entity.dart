import 'dart:typed_data';

import 'package:objectbox/objectbox.dart';

@Entity()
class ThumbnailEntity {
  @Id()
  int id = 0;

  // Using a composite index for faster lookups.
  @Index(type: IndexType.value)
  String? filePath;

  int? pageNumber;

  Uint8List? thumbnailData;

  ThumbnailEntity({this.filePath, this.pageNumber, this.thumbnailData});
}
