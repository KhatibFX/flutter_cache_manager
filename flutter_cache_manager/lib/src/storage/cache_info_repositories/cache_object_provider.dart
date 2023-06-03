import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/src/storage/cache_info_repositories/helper_methods.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../cache_object.dart';
import 'cache_info_repository.dart';

const _tableCacheObject = 'cacheObject';

class CacheObjectProvider extends CacheInfoRepository with CacheInfoRepositoryHelperMethods {
  Database? db;
  String? _path;
  String? databaseName;

  /// Either the path or the database name should be provided.
  /// If the path is provider it should end with '{databaseName}.db',
  /// for example: /data/user/0/com.example.example/databases/imageCache.db
  CacheObjectProvider({String? path, this.databaseName}) : _path = path;

  @override
  Future<bool> open() async {
    if (!shouldOpenOnNewConnection()) {
      return openCompleter!.future;
    }
    var path = await _getPath();
    await File(path).parent.create(recursive: true);
    db = await openDatabase(path, version: 4, onCreate: (Database db, int version) async {
      await db.execute('''
      create table $_tableCacheObject (
        ${CacheObject.columnId} integer primary key,
        ${CacheObject.columnUrl} text,
        ${CacheObject.columnKey} text,
        ${CacheObject.columnPath} text,
        ${CacheObject.columnETag} text,
        ${CacheObject.columnValidTill} integer,
        ${CacheObject.columnTouched} integer,
        ${CacheObject.columnLength} integer,
        ${CacheObject.columnProjectId} text,
        ${CacheObject.columnType} integer
        );
        create unique index $_tableCacheObject${CacheObject.columnKey}
        ON $_tableCacheObject (${CacheObject.columnKey});
      ''');
    }, onUpgrade: (Database db, int oldVersion, int newVersion) async {
      // Migration for adding the optional key, does the following:
      // Adds the new column
      // Creates a unique index for the column
      // Migrates over any existing URLs to keys
      if (oldVersion <= 1) {
        var alreadyHasKeyColumn = false;
        try {
          await db.execute('''
            alter table $_tableCacheObject
            add ${CacheObject.columnKey} text;
            ''');
        } on DatabaseException catch (e) {
          if (!e.isDuplicateColumnError(CacheObject.columnKey)) rethrow;
          alreadyHasKeyColumn = true;
        }
        await db.execute('''
          update $_tableCacheObject
            set ${CacheObject.columnKey} = ${CacheObject.columnUrl}
            where ${CacheObject.columnKey} is null;
          ''');

        if (!alreadyHasKeyColumn) {
          await db.execute('''
            create index $_tableCacheObject${CacheObject.columnKey}
              on $_tableCacheObject (${CacheObject.columnKey});
            ''');
        }
      }
      if (oldVersion <= 2) {
        try {
          await db.execute('''
        alter table $_tableCacheObject
        add ${CacheObject.columnLength} integer;
        ''');
        } on DatabaseException catch (e) {
          if (!e.isDuplicateColumnError(CacheObject.columnLength)) rethrow;
        }
      }
      if (oldVersion <= 3) {
        try {
          await db.execute('''
        alter table $_tableCacheObject
        add ${CacheObject.columnProjectId} text;
        ''');
          await db.execute('''
        alter table $_tableCacheObject
        add ${CacheObject.columnType} integer;
        ''');
        } on DatabaseException catch (e) {
          if (!(e.isDuplicateColumnError(CacheObject.columnProjectId) ||
              e.isDuplicateColumnError(CacheObject.columnType))) rethrow;
        }
      }
    });
    return opened();
  }

  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) {
    if (cacheObject.id == null) {
      return insert(cacheObject);
    } else {
      return update(cacheObject);
    }
  }

  @override
  Future<CacheObject> insert(CacheObject cacheObject, {bool setTouchedToNow = true}) async {
    var id = await db!.insert(
      _tableCacheObject,
      cacheObject.toMap(setTouchedToNow: setTouchedToNow),
    );
    return cacheObject.copyWith(id: id);
  }

  @override
  Future<CacheObject?> get(String key) async {
    List<Map> maps =
        await db!.query(_tableCacheObject, columns: null, where: '${CacheObject.columnKey} = ?', whereArgs: [key]);
    if (maps.isNotEmpty) {
      return CacheObject.fromMap(maps.first.cast<String, dynamic>());
    }
    return null;
  }

  @override
  Future<int> delete(int id) {
    return db!.delete(_tableCacheObject, where: '${CacheObject.columnId} = ?', whereArgs: [id]);
  }

  @override
  Future<int> deleteAll(Iterable<int> ids) {
    return db!.delete(_tableCacheObject, where: '${CacheObject.columnId} IN (' + ids.join(',') + ')');
  }

  @override
  Future<int> update(CacheObject cacheObject, {bool setTouchedToNow = true}) {
    return db!.update(
      _tableCacheObject,
      cacheObject.toMap(setTouchedToNow: setTouchedToNow),
      where: '${CacheObject.columnId} = ?',
      whereArgs: [cacheObject.id],
    );
  }

  @override
  Future<List<CacheObject>> getAllObjects() async {
    return CacheObject.fromMapList(
      await db!.query(_tableCacheObject, columns: null),
    );
  }

  /// For the wakecap cache manager, objects over capacity should be picked based on the following order
  /// unless not enough objects are found:
  /// 1. Objects that belong to another project, preferably the least recently accessed, where the type is other
  /// 2. Objects that belong to another project, preferably the least recently accessed, where the type is blueprint
  /// 3. Objects that belong to the current project, preferably the least recently accessed, where the type is other

  @override
  Future<List<CacheObject>> getObjectsOverCapacity({required int capacity, required String projectId}) async {
    List<CacheObject> overCapacityCacheObjectList = CacheObject.fromMapList(await db!.query(
      _tableCacheObject,
      columns: null,
      orderBy: '${CacheObject.columnTouched} DESC',
      limit: 100,
      offset: capacity,
    ));
    int newLimit = overCapacityCacheObjectList.length;
    debugPrint("Number of objects over capacity: $newLimit");
    List<CacheObject> result = [];
    if (overCapacityCacheObjectList.isNotEmpty) {
      // Database is over capacity. Query the database and pick objects based on the order above.
      List<CacheObject> otherProjectOtherCacheObjectList = CacheObject.fromMapList(await db!.query(
        _tableCacheObject,
        columns: null,
        orderBy: '${CacheObject.columnTouched} ASC',
        where: '${CacheObject.columnProjectId} != ? AND ${CacheObject.columnType} = ?',
        whereArgs: [projectId, CacheObjectType.other.index],
        limit: newLimit,
      ));
      debugPrint("Number of deletable other objects from other projects: ${otherProjectOtherCacheObjectList.length}");
      result.addAll(otherProjectOtherCacheObjectList);
      newLimit -= otherProjectOtherCacheObjectList.length;
      if (newLimit > 0) {
        List<CacheObject> otherProjectBlueprintCacheObjectList = CacheObject.fromMapList(await db!.query(
          _tableCacheObject,
          columns: null,
          orderBy: '${CacheObject.columnTouched} ASC',
          where: '${CacheObject.columnProjectId} != ? AND ${CacheObject.columnType} = ?',
          whereArgs: [projectId, CacheObjectType.blueprint.index],
          limit: newLimit,
        ));
        debugPrint(
            "Number of deletable blueprint objects from other projects: ${otherProjectBlueprintCacheObjectList.length}");
        result.addAll(otherProjectBlueprintCacheObjectList);
        newLimit -= otherProjectBlueprintCacheObjectList.length;
        if (newLimit > 0) {
          List<CacheObject> currentProjectOtherCacheObjectList = CacheObject.fromMapList(await db!.query(
            _tableCacheObject,
            columns: null,
            orderBy: '${CacheObject.columnTouched} ASC',
            where: '${CacheObject.columnProjectId} = ? AND ${CacheObject.columnType} = ?',
            whereArgs: [projectId, CacheObjectType.other.index],
            limit: newLimit,
          ));
          debugPrint(
              "Number of deletable other objects from this project: ${currentProjectOtherCacheObjectList.length}");
          result.addAll(currentProjectOtherCacheObjectList);
        }
      }
    }
    return result;
  }

  /// For the wakecap cache manager, objects that are old should be picked where the type is other
  @override
  Future<List<CacheObject>> getOldObjects({required Duration maxAge}) async {
    return CacheObject.fromMapList(await db!.query(
      _tableCacheObject,
      where: '${CacheObject.columnTouched} < ? AND ${CacheObject.columnType} = ?',
      columns: null,
      whereArgs: [DateTime.now().subtract(maxAge).millisecondsSinceEpoch, CacheObjectType.other.index],
      limit: 100,
    ));
  }

  @override
  Future<bool> close() async {
    if (!shouldClose()) return false;
    await db!.close();
    return true;
  }

  @override
  Future deleteDataFile() async {
    await _getPath();
  }

  @override
  Future<bool> exists() async {
    final path = await _getPath();
    return File(path).exists();
  }

  Future<String> _getPath() async {
    Directory directory;
    if (_path != null) {
      directory = File(_path!).parent;
    } else {
      directory = (await getApplicationSupportDirectory());
    }
    await directory.create(recursive: true);
    if (_path == null || !_path!.endsWith('.db')) {
      _path = join(directory.path, '$databaseName.db');
    }
    await _migrateOldDbPath(_path!);
    return _path!;
  }

  // Migration for pre-V2 path on iOS and macOS
  Future _migrateOldDbPath(String newDbPath) async {
    final oldDbPath = join((await getDatabasesPath()), '$databaseName.db');
    if (oldDbPath != newDbPath && await File(oldDbPath).exists()) {
      try {
        await File(oldDbPath).rename(newDbPath);
      } on FileSystemException {
        // If we can not read the old db, a new one will be created.
      }
    }
  }
}
