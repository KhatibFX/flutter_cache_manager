import 'package:flutter_cache_manager/src/storage/cache_object.dart';

class AdditionalConfig {
  final String? projectId;
  final Function({required List<CacheObject> cacheObjects})? onRemoved;
  final Map<String, dynamic>? extras;
  final List<MaxAgePolicy>? maxAgePolicies;
  final List<OverCapacityPolicy>? overCapacityPolicies;
  const AdditionalConfig({this.projectId, this.onRemoved, this.extras, this.maxAgePolicies, this.overCapacityPolicies});
}

class MaxAgePolicy {
  final Duration maxAge;
  final String? cacheObjectType;

  MaxAgePolicy({required this.maxAge, required this.cacheObjectType});
}

class OverCapacityPolicy {
  final String projectIdComparator;
  final String? projectId;
  final String cacheObjectTypeComparator;
  final String? cacheObjectType;

  OverCapacityPolicy({required this.projectIdComparator, required this.projectId, required this.cacheObjectTypeComparator, required this.cacheObjectType});
}
