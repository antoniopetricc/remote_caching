import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:remote_caching/src/models/caching_stats.dart';
import 'package:sqflite/sqflite.dart';

// Export the main class
export 'remote_caching_impl.dart' show RemoteCaching;

/// A Flutter package for caching remote API calls with configurable duration.
///
/// Usage:
/// ```dart
/// await RemoteCaching.instance.init();
///
/// final data = await RemoteCaching.instance.call(
///   "user_profile",
///   cacheDuration: Duration(minutes: 30),
///   remote: () async => await fetchUserProfile(),
///   fromJson: (json) => UserProfile.fromJson(json as Map<String, dynamic>),
/// );
/// ```
class RemoteCaching {
  factory RemoteCaching() => _instance;
  RemoteCaching._internal();
  static final RemoteCaching _instance = RemoteCaching._internal();

  static RemoteCaching get instance => _instance;

  Database? _database;
  Duration _defaultCacheDuration = const Duration(hours: 1);
  bool _isInitialized = false;
  bool _verboseMode = false;

  void _logInfo(String message) {
    if (_verboseMode) {
      log(
        '🔵 [RemoteCaching] $message',
        name: 'RemoteCaching',
        level: 800, // INFO level
      );
    }
  }

  void _logError(String message, {StackTrace? stackTrace}) {
    if (_verboseMode) {
      log(
        '🔴 [RemoteCaching ERROR] $message',
        name: 'RemoteCaching',
        level: 1000, // SEVERE level
        stackTrace: stackTrace,
      );
    }
  }

  /// Initialize the caching system
  Future<void> init({
    Duration? defaultCacheDuration,
    bool verboseMode = kDebugMode,
  }) async {
    if (_isInitialized) return;

    _defaultCacheDuration = defaultCacheDuration ?? _defaultCacheDuration;
    _verboseMode = verboseMode;
    _database = await _initDatabase();
    _isInitialized = true;

    await _cleanupExpiredEntries();
  }

  /// Execute a remote call with caching
  Future<T> call<T>(
    String key, {
    required Future<T> Function() remote,
    required T Function(Object? json) fromJson,
    Duration? cacheDuration,
    DateTime? cacheExpiring,
    bool forceRefresh = false,
  }) async {
    if (!_isInitialized) {
      throw StateError('RemoteCaching must be initialized before use.');
    }

    assert(
      cacheDuration == null || cacheExpiring == null,
      'You cannot specify both cacheDuration and cacheExpiring at the same time.',
    );

    final expiresAt =
        cacheExpiring ??
        DateTime.now().add(cacheDuration ?? _defaultCacheDuration);

    if (!forceRefresh) {
      final cached = await _getCachedData<T>(key, fromJson: fromJson);
      if (cached != null) {
        _logInfo('Cached data found for key: $key');
        return cached;
      }
    }

    final data = await remote();
    _logInfo('Data fetched from remote for key: $key');
    await _cacheData(key, data, expiresAt);
    _logInfo('Data cached for key: $key');
    return data;
  }

  /// Get cached data if valid
  Future<T?> _getCachedData<T>(
    String key, {
    required T Function(Object? json) fromJson,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final result = await _database?.query(
      'cache',
      where: 'key = ?',
      whereArgs: [key],
    );

    if (result != null && result.isNotEmpty) {
      final expiresAt = result.first['expires_at']! as int;
      if (expiresAt > now) {
        _logInfo('Cached data found for key: $key');
        final dataString = result.first['data']! as String;
        try {
          final decoded = jsonDecode(dataString);
          try {
            return fromJson(decoded);
          } catch (e, st) {
            _logError(
              'Deserialization error (fromJson) for key $key: $e',
              stackTrace: st,
            );
            return null;
          }
        } catch (e, st) {
          _logError(
            'Deserialization error (jsonDecode) for key $key: $e',
            stackTrace: st,
          );
          return null;
        }
      } else {
        _logInfo('Cached data expired for key: $key');
        // Remove the expired data
        await _database?.delete('cache', where: 'key = ?', whereArgs: [key]);
      }
    }
    _logInfo('No cached data found for key: $key');
    return null;
  }

  /// Cache data with expiration
  Future<void> _cacheData<T>(String key, T data, DateTime expiresAt) async {
    final now = DateTime.now();
    String? dataString;
    try {
      dataString = jsonEncode(data);
    } catch (e, st) {
      _logError(
        'Serialization error (jsonEncode) for key $key: $e',
        stackTrace: st,
      );
      return; // Non salvo nulla in cache
    }

    await _database?.insert('cache', {
      'key': key,
      'data': dataString,
      'created_at': now.millisecondsSinceEpoch,
      'expires_at': expiresAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Initialize the SQLite database
  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'remote_caching.db');

    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE cache (
            key TEXT PRIMARY KEY,
            data TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_expires_at ON cache (expires_at)');
      },
    );
  }

  /// Cleanup expired entries from the cache
  Future<void> _cleanupExpiredEntries() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _database?.delete('cache', where: 'expires_at < ?', whereArgs: [now]);
  }

  /// Clear the entire cache
  Future<void> clearCache() async {
    if (!_isInitialized) return;
    await _database?.delete('cache');
  }

  /// Clear a specific cache entry
  Future<void> clearCacheForKey(String key) async {
    if (!_isInitialized) return;
    await _database?.delete('cache', where: 'key = ?', whereArgs: [key]);
  }

  /// Get cache statistics
  Future<CachingStats> getCacheStats() async {
    if (!_isInitialized) {
      throw StateError('RemoteCaching must be initialized before use.');
    }

    final stats = await _database?.rawQuery(
      'SELECT COUNT(*) as total_entries, SUM(LENGTH(data)) as total_size FROM cache',
    );

    final expired = await _database?.rawQuery(
      'SELECT COUNT(*) as expired_entries FROM cache WHERE expires_at < ?',
      [DateTime.now().millisecondsSinceEpoch],
    );

    return CachingStats(
      totalEntries: (stats?.first['total_entries'] as int?) ?? 0,
      totalSizeBytes: (stats?.first['total_size'] as int?) ?? 0,
      expiredEntries: (expired?.first['expired_entries'] as int?) ?? 0,
    );
  }

  /// Dispose of the cache system
  Future<void> dispose() async {
    await _database?.close();
    _isInitialized = false;
  }
}
