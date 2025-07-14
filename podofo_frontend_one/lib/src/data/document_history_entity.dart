import 'package:objectbox/objectbox.dart';

@Entity()
class DocumentHistoryEntity {
  DocumentHistoryEntity({
    this.id = 0,
    required this.filePath,
    required this.lastOpened,
  });

  @Id()
  int id;

  @Unique(onConflict: ConflictStrategy.replace)
  String filePath;

  @Property(type: PropertyType.date)
  DateTime lastOpened;
}
