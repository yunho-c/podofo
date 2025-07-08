import 'package:objectbox/objectbox.dart';

@Entity()
class DocumentEntity {
  DocumentEntity({
    this.id = 0,
    required this.filePath,
    this.lastOpenedPage,
  });

  @Id()
  int id;

  final String filePath;
  int? lastOpenedPage;
}
