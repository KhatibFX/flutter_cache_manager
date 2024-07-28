import 'package:flutter_cache_manager/src/storage/cache_object.dart';

class AdditionalConfig {
  final String? projectId;
  final Function({required List<CacheObject> cacheObjects})? onRemoved;
  final Map<String, dynamic>? extras;

  const AdditionalConfig({this.projectId, this.onRemoved, this.extras});
}
