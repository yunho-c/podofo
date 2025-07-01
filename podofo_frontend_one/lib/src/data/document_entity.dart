import 'package:objectbox/objectbox.dart';

@Entity()
class DocumentEntity {
  DocumentEntity({
    this.id = 0,
    required this.filePath,
  });

  @Id()
  int id;

  final String filePath;
}
