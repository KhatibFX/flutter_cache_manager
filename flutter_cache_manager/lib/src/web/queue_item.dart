import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class QueueItem {
  final String url;
  final String key;
  final Map<String, String>? headers;
  final String? projectId;
  final CacheObjectType? type;

  QueueItem(this.url, this.key, this.headers, {this.projectId, this.type});
}
