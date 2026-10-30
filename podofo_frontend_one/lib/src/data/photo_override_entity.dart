import 'package:objectbox/objectbox.dart';

/// Reading preferences survive closing a tab and never modify the PDF.
@Entity()
class PhotoOverrideEntity {
  PhotoOverrideEntity({
    this.id = 0,
    required this.documentHash,
    required this.decisions,
  });

  @Id()
  int id;
  @Unique()
  String documentHash;
  String decisions;
}
