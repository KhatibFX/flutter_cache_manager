class QueueItem {
  final String url;
  final String key;
  final Map<String, String>? headers;
  final String? projectId;
  final String? cacheObjectType;

  const QueueItem(this.url, this.key, this.headers, {this.projectId, this.cacheObjectType});
}
