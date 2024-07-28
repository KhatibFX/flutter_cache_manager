import 'dart:async';

import 'package:flutter_cache_manager/src/storage/file_system/file_system.dart';

import '../flutter_cache_manager.dart';

///Flutter Cache Manager
///Copyright (c) 2019 Rene Floor
///Released under MIT License.

class CacheStore {
  Duration cleanupRunMinInterval = const Duration(seconds: 10);

  final _futureCache = <String, Future<CacheObject?>>{};
  final _memCache = <String, CacheObject>{};

  FileSystem fileSystem;

  final Config _config;
  AdditionalConfig? _additionalConfig;
  String get storeKey => _config.cacheKey;
  final Future<CacheInfoRepository> _cacheInfoRepository;
  int get _capacity => _config.maxNrOfCacheObjects;
  Duration get _maxAge => _config.stalePeriod;
  String? get _projectId => _additionalConfig?.projectId;
  Function({required List<CacheObject> cacheObjects})? get _onRemoved => _additionalConfig?.onRemoved;

  DateTime lastCleanupRun = DateTime.now();
  Timer? _scheduledCleanup;

  CacheStore(Config config)
      : _config = config,
        fileSystem = config.fileSystem,
        _cacheInfoRepository = config.repo.open().then((value) => config.repo);

  Future<void> setAdditionalConfig(AdditionalConfig additionalConfig) async {
    _additionalConfig = additionalConfig;
    await ((await _cacheInfoRepository).setAdditionalConfig(additionalConfig));
  }

  Future<FileInfo?> getFile(String key, {bool ignoreMemCache = false}) async {
    final cacheObject = await retrieveCacheData(key, ignoreMemCache: ignoreMemCache);
    if (cacheObject == null) {
      return null;
    }
    final file = await fileSystem.createFile(cacheObject.relativePath);
    cacheLogger.log('CacheManager: Loaded $key from cache', CacheManagerLogLevel.verbose);

    return FileInfo(
      file,
      FileSource.Cache,
      cacheObject.validTill,
      cacheObject.url,
    );
  }

  Future<void> putFile(CacheObject cacheObject) async {
    _memCache[cacheObject.key] = cacheObject;
    final dynamic out = await _updateCacheDataInDatabase(cacheObject);

    // We update the cache object with the id if returned by the repository
    if (out is CacheObject && out.id != null) {
      _memCache[cacheObject.key] = cacheObject.copyWith(id: out.id);
    }
  }

  Future<CacheObject?> retrieveCacheData(String key, {bool ignoreMemCache = false}) async {
    if (!ignoreMemCache && _memCache.containsKey(key)) {
      if (await _fileExists(_memCache[key])) {
        return _memCache[key];
      }
    }
    if (!_futureCache.containsKey(key)) {
      final completer = Completer<CacheObject?>();
      unawaited(_getCacheDataFromDatabase(key).then((cacheObject) async {
        if (cacheObject?.id != null && !await _fileExists(cacheObject)) {
          final provider = await _cacheInfoRepository;
          await provider.setAdditionalConfig(_additionalConfig);
          await provider.delete(cacheObject!.id!);
          cacheObject = null;
        }

        if (cacheObject == null) {
          _memCache.remove(key);
        } else {
          _memCache[key] = cacheObject;
        }
        completer.complete(cacheObject);
        _futureCache.remove(key);
      }));
      _futureCache[key] = completer.future;
    }
    return _futureCache[key];
  }

  Future<FileInfo?> getFileFromMemory(String key) async {
    final cacheObject = _memCache[key];
    if (cacheObject == null) {
      return null;
    }
    final file = await fileSystem.createFile(cacheObject.relativePath);
    return FileInfo(file, FileSource.Cache, cacheObject.validTill, cacheObject.url);
  }

  Future<bool> _fileExists(CacheObject? cacheObject) async {
    if (cacheObject == null) {
      return false;
    }
    var file = await fileSystem.createFile(cacheObject.relativePath);
    return file.exists();
  }

  Future<CacheObject?> _getCacheDataFromDatabase(String key) async {
    final provider = await _cacheInfoRepository;
    await provider.setAdditionalConfig(_additionalConfig);
    final data = await provider.get(key);
    if (await _fileExists(data)) {
      unawaited(_updateCacheDataInDatabase(data!));
    }
    _scheduleCleanup();
    return data;
  }

  void _scheduleCleanup() {
    if (_scheduledCleanup != null) {
      return;
    }
    _scheduledCleanup = Timer(cleanupRunMinInterval, () {
      _scheduledCleanup = null;
      _cleanupCache();
    });
  }

  Future<dynamic> _updateCacheDataInDatabase(CacheObject cacheObject) async {
    final provider = await _cacheInfoRepository;
    await provider.setAdditionalConfig(_additionalConfig);
    return provider.updateOrInsert(cacheObject);
  }

  Future<void> _cleanupCache() async {
    final toRemove = <int>[];
    final provider = await _cacheInfoRepository;
    await provider.setAdditionalConfig(_additionalConfig);

    if (_projectId != null) {
      final overCapacity = await provider.getObjectsOverCapacity(capacity: _capacity, projectId: _projectId!);
      for (final cacheObject in overCapacity) {
        unawaited(_removeCachedFile(cacheObject, toRemove));
      }
    }

    final oldObjects = await provider.getOldObjects(maxAge: _maxAge);
    for (final cacheObject in oldObjects) {
      unawaited(_removeCachedFile(cacheObject, toRemove));
    }

    await provider.deleteAll(toRemove);
  }

  Future<void> emptyCache() async {
    final provider = await _cacheInfoRepository;
    await provider.setAdditionalConfig(_additionalConfig);
    final toRemove = <int>[];
    final allObjects = await provider.getAllObjects();
    for (final cacheObject in allObjects) {
      unawaited(_removeCachedFile(cacheObject, toRemove));
    }
    await provider.deleteAll(toRemove);
  }

  void emptyMemoryCache() {
    _memCache.clear();
  }

  Future<void> removeCachedFile(CacheObject cacheObject) async {
    final provider = await _cacheInfoRepository;
    await provider.setAdditionalConfig(_additionalConfig);
    final toRemove = <int>[];
    await _removeCachedFile(cacheObject, toRemove);
    await provider.deleteAll(toRemove);
  }

  Future<void> _removeCachedFile(CacheObject cacheObject, List<int> toRemove) async {
    if (toRemove.contains(cacheObject.id)) return;

    toRemove.add(cacheObject.id!);
    if (_memCache.containsKey(cacheObject.key)) {
      _memCache.remove(cacheObject.key);
    }
    if (_futureCache.containsKey(cacheObject.key)) {
      _futureCache.remove(cacheObject.key);
    }
    final file = await fileSystem.createFile(cacheObject.relativePath);
    if (await file.exists()) {
      await file.delete();
    }
    if (_onRemoved != null) {
      _onRemoved!(cacheObjects: [cacheObject]);
    }
  }

  Future<void> dispose() async {
    final provider = await _cacheInfoRepository;
    await provider.setAdditionalConfig(_additionalConfig);
    await provider.close();
  }
}
