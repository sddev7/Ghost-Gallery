import 'package:objectbox/objectbox.dart';

@Entity()
class MediaVector {
  @Id()
  int id = 0;

  @Index()
  final String mediaId;

  @HnswIndex(dimensions: 256, distanceType: VectorDistanceType.cosine)
  @Property(type: PropertyType.floatVector)
  List<double>? embedding;

  MediaVector({
    this.id = 0,
    required this.mediaId,
    this.embedding,
  });
}
