/// Subsonic 服务端数据访问层（Dart 侧，sqlite3 直写用户库 user.db）。
///
/// SPlayer 的 tracks 表是扁平结构（album/artist 以 JSON 嵌在 track 行里），
/// 没有 Navidrome 那样的独立 album/artist 表。因此：
///   - track id   = tracks.id（原生）
///   - album id   = md5(album.name) 的 hex
///   - artist id  = md5(artist.name) 的 hex
/// 反查 album/artist 时遍历名称集合匹配 md5（曲库规模下可接受）。
///
/// 凭据加密复用 [SubsonicController]（FFI 调 Go crypto，格式与 TS encryptString 兼容）。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'subsonic_controller.dart';

/// 计算 album/artist 稳定 ID（与 TS albumIdOf/artistIdOf 一致）。
String subsonicAlbumIdOf(String name) => md5.convert(utf8.encode(name)).toString();
String subsonicArtistIdOf(String name) => md5.convert(utf8.encode(name)).toString();

/// 推导独立用户库路径：与媒体库同目录的 user.db（与 Go 侧 DefaultUserDBPath 一致，
/// 避免依赖 path 包：仅按目录分割取文件名替换）。
String subsonicUserDbPath(String libraryDbPath) {
  final sep = libraryDbPath.contains('\\') ? '\\' : '/';
  final idx = libraryDbPath.lastIndexOf(sep);
  final dir = idx < 0 ? '.' : libraryDbPath.substring(0, idx + 1);
  return '${dir}user.db';
}

/// 生成 UUID（对齐 TS randomUUID）。
String _uuid() {
  final rng = Random.secure();
  final b = List<int>.generate(16, (_) => rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}'
      '-${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
}

/* ------------------------------------------------------------------ */
/* 模型                                                                */
/* ------------------------------------------------------------------ */

class SubsonicUser {
  SubsonicUser({
    required this.id,
    required this.username,
    required this.password,
    required this.isAdmin,
    required this.createdAt,
  });
  final String id;
  final String username;
  final String password; // 明文（仅运行时，落盘为密文）
  final bool isAdmin;
  final int createdAt;
}

class SubsonicPlaylist {
  SubsonicPlaylist({
    required this.id,
    required this.userId,
    required this.name,
    this.comment,
    this.public = false,
    required this.createdAt,
    required this.updatedAt,
    required this.trackIds,
  });
  final String id;
  final String userId;
  final String name;
  final String? comment;
  final bool public;
  final int createdAt;
  final int updatedAt;
  final List<String> trackIds;
}

class SubsonicShare {
  SubsonicShare({
    required this.id,
    required this.userId,
    required this.name,
    this.description,
    required this.url,
    this.expiresAt,
    required this.createdAt,
    required this.visitCount,
    required this.trackIds,
  });
  final String id;
  final String userId;
  final String name;
  final String? description;
  final String url;
  final int? expiresAt;
  final int createdAt;
  final int visitCount;
  final List<String> trackIds;
}

/// 收藏目标类型。
enum SubsonicStarType { track, album, artist }

/* ------------------------------------------------------------------ */
/* 数据访问                                                            */
/* ------------------------------------------------------------------ */

/// Subsonic 服务端管理层（sqlite3 直写用户库）。
class SubsonicAdmin {
  SubsonicAdmin._(this._db, this._controller);

  final Database _db;
  final SubsonicController _controller;

  /// 打开独立用户库（user.db）并绑定服务控制器（凭据加解密走 FFI）。
  ///
  /// 用户库路径经 [subsonicUserDbPath] 从媒体库路径推导；subsonic_* 表由
  /// Dart 侧幂等 CREATE IF NOT EXISTS 兜底（Go 侧 EnsureTables 已建过一次）。
  static SubsonicAdmin open(SubsonicController controller, String userDbPath) {
    final db = sqlite3.open(userDbPath);
    _ensureTables(db);
    return SubsonicAdmin._(db, controller);
  }

  static void _ensureTables(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS subsonic_users (
        id TEXT PRIMARY KEY,
        username TEXT NOT NULL UNIQUE,
        password_cipher TEXT NOT NULL,
        is_admin INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS subsonic_starred (
        user_id TEXT NOT NULL,
        target_id TEXT NOT NULL,
        target_type TEXT NOT NULL,
        starred_at INTEGER NOT NULL,
        PRIMARY KEY (user_id, target_id, target_type)
      );
      CREATE TABLE IF NOT EXISTS subsonic_playlists (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        name TEXT NOT NULL,
        comment TEXT,
        public INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS subsonic_playlist_entries (
        playlist_id TEXT NOT NULL,
        track_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        PRIMARY KEY (playlist_id, position)
      );
      CREATE TABLE IF NOT EXISTS subsonic_shares (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        name TEXT NOT NULL,
        description TEXT,
        url TEXT NOT NULL,
        expires_at INTEGER,
        created_at INTEGER NOT NULL,
        visit_count INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS subsonic_share_entries (
        share_id TEXT NOT NULL,
        track_id TEXT NOT NULL,
        PRIMARY KEY (share_id, track_id)
      );
    ''');
  }

  void close() => _db.close();

  /* ------------------------------- 用户 ------------------------------- */

  List<SubsonicUser> listUsers() {
    final rows = _db.select('SELECT * FROM subsonic_users ORDER BY created_at');
    return rows.map(_rowToUser).toList();
  }

  SubsonicUser? getUserByUsername(String username) {
    final rows = _db.select(
        'SELECT * FROM subsonic_users WHERE username = ?', [username]);
    return rows.isEmpty ? null : _rowToUser(rows.first);
  }

  /// 创建用户（用户名唯一；密码落盘前加密）。
  SubsonicUser createUser({
    required String username,
    required String password,
    bool isAdmin = false,
  }) {
    if (getUserByUsername(username) != null) {
      throw StateError('username already exists');
    }
    final user = SubsonicUser(
      id: _uuid(),
      username: username,
      password: password,
      isAdmin: isAdmin,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final cipher = _controller.encrypt(password) ?? password;
    _db.execute(
      'INSERT INTO subsonic_users (id, username, password_cipher, is_admin, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [user.id, user.username, cipher, user.isAdmin ? 1 : 0, user.createdAt],
    );
    return user;
  }

  /// 更新用户（password/isAdmin 可选，空则不改）。
  void updateUser(String id, {String? password, bool? isAdmin}) {
    final sets = <String>[];
    final params = <Object?>[];
    if (password != null && password.isNotEmpty) {
      sets.add('password_cipher = ?');
      params.add(_controller.encrypt(password) ?? password);
    }
    if (isAdmin != null) {
      sets.add('is_admin = ?');
      params.add(isAdmin ? 1 : 0);
    }
    if (sets.isEmpty) return;
    params.add(id);
    _db.execute('UPDATE subsonic_users SET ${sets.join(', ')} WHERE id = ?', params);
  }

  /// 删除用户（同时清理关联数据）。
  void deleteUser(String id) {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM subsonic_starred WHERE user_id = ?', [id]);
      _db.execute('DELETE FROM subsonic_playlist_entries WHERE playlist_id IN '
          '(SELECT id FROM subsonic_playlists WHERE user_id = ?)', [id]);
      _db.execute('DELETE FROM subsonic_playlists WHERE user_id = ?', [id]);
      _db.execute('DELETE FROM subsonic_share_entries WHERE share_id IN '
          '(SELECT id FROM subsonic_shares WHERE user_id = ?)', [id]);
      _db.execute('DELETE FROM subsonic_shares WHERE user_id = ?', [id]);
      _db.execute('DELETE FROM subsonic_users WHERE id = ?', [id]);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  SubsonicUser _rowToUser(Row row) {
    final cipher = row['password_cipher'] as String;
    return SubsonicUser(
      id: row['id'] as String,
      username: row['username'] as String,
      password: _controller.decrypt(cipher) ?? cipher,
      isAdmin: (row['is_admin'] as int?) == 1,
      createdAt: (row['created_at'] as int?) ?? 0,
    );
  }

  /* ------------------------------- 收藏 ------------------------------- */

  void star(String userId, String targetId, SubsonicStarType type) {
    _db.execute(
      'INSERT OR IGNORE INTO subsonic_starred (user_id, target_id, target_type, starred_at) '
      'VALUES (?, ?, ?, ?)',
      [userId, targetId, type.name, DateTime.now().millisecondsSinceEpoch],
    );
  }

  void unstar(String userId, String targetId, SubsonicStarType type) {
    _db.execute(
      'DELETE FROM subsonic_starred WHERE user_id = ? AND target_id = ? AND target_type = ?',
      [userId, targetId, type.name],
    );
  }

  bool isStarred(String userId, String targetId, SubsonicStarType type) {
    final rows = _db.select(
      'SELECT 1 FROM subsonic_starred WHERE user_id = ? AND target_id = ? AND target_type = ?',
      [userId, targetId, type.name],
    );
    return rows.isNotEmpty;
  }

  /// 获取用户全部收藏 ID。
  ({List<String> tracks, List<String> albums, List<String> artists}) getStarredIds(
      String userId) {
    final rows = _db.select(
        'SELECT target_id, target_type FROM subsonic_starred WHERE user_id = ?',
        [userId]);
    final tracks = <String>[];
    final albums = <String>[];
    final artists = <String>[];
    for (final r in rows) {
      switch (r['target_type'] as String) {
        case 'track':
          tracks.add(r['target_id'] as String);
        case 'album':
          albums.add(r['target_id'] as String);
        case 'artist':
          artists.add(r['target_id'] as String);
      }
    }
    return (tracks: tracks, albums: albums, artists: artists);
  }

  /* ------------------------------ 播放列表 ----------------------------- */

  List<SubsonicPlaylist> listPlaylists(String userId) {
    final rows = _db.select(
        'SELECT * FROM subsonic_playlists WHERE user_id = ? OR public = 1 '
        'ORDER BY updated_at DESC', [userId]);
    return rows.map(_rowToPlaylist).toList();
  }

  SubsonicPlaylist? getPlaylist(String id, String userId) {
    final rows = _db.select(
        'SELECT * FROM subsonic_playlists WHERE id = ? AND (user_id = ? OR public = 1)',
        [id, userId]);
    return rows.isEmpty ? null : _rowToPlaylist(rows.first);
  }

  SubsonicPlaylist createPlaylist(
    String userId,
    String name,
    List<String> trackIds, {
    String? comment,
    bool isPublic = false,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final pl = SubsonicPlaylist(
      id: _uuid(),
      userId: userId,
      name: name,
      comment: comment,
      public: isPublic,
      createdAt: now,
      updatedAt: now,
      trackIds: trackIds,
    );
    _db.execute('BEGIN');
    try {
      _db.execute(
        'INSERT INTO subsonic_playlists (id, user_id, name, comment, public, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [pl.id, pl.userId, pl.name, pl.comment, pl.public ? 1 : 0, pl.createdAt, pl.updatedAt],
      );
      for (var i = 0; i < pl.trackIds.length; i++) {
        _db.execute(
          'INSERT INTO subsonic_playlist_entries (playlist_id, track_id, position) VALUES (?, ?, ?)',
          [pl.id, pl.trackIds[i], i],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return pl;
  }

  void updatePlaylist(
    String id,
    String userId, {
    String? name,
    String? comment,
    bool? isPublic,
    List<String>? trackIds,
  }) {
    final existing = getPlaylist(id, userId);
    if (existing == null) throw StateError('playlist not found');
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('BEGIN');
    try {
      final sets = <String>['updated_at = ?'];
      final params = <Object?>[now];
      if (name != null) {
        sets.add('name = ?');
        params.add(name);
      }
      if (comment != null) {
        sets.add('comment = ?');
        params.add(comment);
      }
      if (isPublic != null) {
        sets.add('public = ?');
        params.add(isPublic ? 1 : 0);
      }
      params.add(id);
      _db.execute(
          'UPDATE subsonic_playlists SET ${sets.join(', ')} WHERE id = ?', params);
      if (trackIds != null) {
        _db.execute('DELETE FROM subsonic_playlist_entries WHERE playlist_id = ?', [id]);
        for (var i = 0; i < trackIds.length; i++) {
          _db.execute(
            'INSERT INTO subsonic_playlist_entries (playlist_id, track_id, position) VALUES (?, ?, ?)',
            [id, trackIds[i], i],
          );
        }
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void deletePlaylist(String id, String userId) {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM subsonic_playlist_entries WHERE playlist_id = ?', [id]);
      _db.execute(
          'DELETE FROM subsonic_playlists WHERE id = ? AND user_id = ?', [id, userId]);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  SubsonicPlaylist _rowToPlaylist(Row row) {
    final ids = _db.select(
        'SELECT track_id FROM subsonic_playlist_entries WHERE playlist_id = ? ORDER BY position',
        [row['id'] as String]);
    return SubsonicPlaylist(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      name: row['name'] as String,
      comment: row['comment'] as String?,
      public: (row['public'] as int?) == 1,
      createdAt: (row['created_at'] as int?) ?? 0,
      updatedAt: (row['updated_at'] as int?) ?? 0,
      trackIds: ids.map((r) => r['track_id'] as String).toList(),
    );
  }

  /* ------------------------------- 分享 ------------------------------- */

  List<SubsonicShare> listShares(String userId) {
    final rows = _db.select(
        'SELECT * FROM subsonic_shares WHERE user_id = ? ORDER BY created_at DESC',
        [userId]);
    return rows.map(_rowToShare).toList();
  }

  SubsonicShare? getShare(String id) {
    final rows = _db.select('SELECT * FROM subsonic_shares WHERE id = ?', [id]);
    return rows.isEmpty ? null : _rowToShare(rows.first);
  }

  SubsonicShare createShare(
    String userId,
    String name,
    List<String> trackIds, {
    String? description,
    int? expiresAt,
    String baseUrl = '',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid();
    final share = SubsonicShare(
      id: id,
      userId: userId,
      name: name,
      description: description,
      url: '$baseUrl/ext/share/$id',
      expiresAt: expiresAt,
      createdAt: now,
      visitCount: 0,
      trackIds: trackIds,
    );
    _db.execute('BEGIN');
    try {
      _db.execute(
        'INSERT INTO subsonic_shares (id, user_id, name, description, url, expires_at, created_at, visit_count) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [share.id, share.userId, share.name, share.description, share.url, share.expiresAt,
         share.createdAt, 0],
      );
      for (final tid in share.trackIds) {
        _db.execute(
            'INSERT INTO subsonic_share_entries (share_id, track_id) VALUES (?, ?)',
            [share.id, tid]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return share;
  }

  void updateShare(String id, String userId,
      {String? description, int? expiresAt, bool clearExpiresAt = false}) {
    final sets = <String>[];
    final params = <Object?>[];
    if (description != null) {
      sets.add('description = ?');
      params.add(description);
    }
    if (clearExpiresAt || expiresAt != null) {
      sets.add('expires_at = ?');
      params.add(expiresAt);
    }
    if (sets.isEmpty) return;
    params.add(id);
    params.add(userId);
    _db.execute(
        'UPDATE subsonic_shares SET ${sets.join(', ')} WHERE id = ? AND user_id = ?',
        params);
  }

  void deleteShare(String id, String userId) {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM subsonic_share_entries WHERE share_id = ?', [id]);
      _db.execute(
          'DELETE FROM subsonic_shares WHERE id = ? AND user_id = ?', [id, userId]);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void incrementShareVisit(String id) {
    _db.execute(
        'UPDATE subsonic_shares SET visit_count = visit_count + 1 WHERE id = ?', [id]);
  }

  SubsonicShare _rowToShare(Row row) {
    final ids = _db.select(
        'SELECT track_id FROM subsonic_share_entries WHERE share_id = ?',
        [row['id'] as String]);
    return SubsonicShare(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      name: row['name'] as String,
      description: row['description'] as String?,
      url: row['url'] as String,
      expiresAt: row['expires_at'] as int?,
      createdAt: (row['created_at'] as int?) ?? 0,
      visitCount: (row['visit_count'] as int?) ?? 0,
      trackIds: ids.map((r) => r['track_id'] as String).toList(),
    );
  }
}
