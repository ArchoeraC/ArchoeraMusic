// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 媒体库「编辑元数据」：单文件标签读写。
///
/// 直连 libarchoera_scraper 的读/写标签 C ABI（`archoera_scraper_read_tags`
/// / `archoera_scraper_write_tags`），Dart 侧只做 JSON ↔ [TrackTags] 映射。
/// 每次调用在短生命周期 isolate 内加载库、执行、随即卸载（[ScraperBindings.release]），
/// 避免阻塞 UI 线程，也不让刮削库常驻。
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'scraper_bindings.dart';

/// 标签读写失败（定位/解析/原生报错）。
class TagEditorException implements Exception {
  TagEditorException(this.message);

  final String message;

  @override
  String toString() => 'TagEditorException: $message';
}

/// 单文件标签快照（读出的或待写入的字段集合）。
class TrackTags {
  TrackTags({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.composer = '',
    this.genre = '',
    this.lyrics = '',
    this.coverMime = '',
    this.trackNumber = 0,
    this.discNumber = 0,
    this.year = 0,
    this.durationMs = 0,
    this.coverBytes,
    this.hasCover = false,
  });

  final String title;
  final String artist;
  final String album;
  final String albumArtist;
  final String composer;
  final String genre;
  final String lyrics;

  /// 封面 MIME（如 `image/jpeg`）；无封面时为空。
  final String coverMime;

  final int trackNumber;
  final int discNumber;
  final int year;

  /// 音频时长（毫秒）；仅读取时有意义。
  final int durationMs;

  /// 解码后的封面二进制；null 表示无封面（写入时表示清除）。
  final Uint8List? coverBytes;

  /// 是否含封面（读取时由原生返回）。
  final bool hasCover;

  /// copyWith 哨兵：允许把 [coverBytes] 显式置空（清除封面）。
  static const Object _unset = Object();

  /// 复制并覆盖指定字段。[coverBytes] 传 null 表示清除封面
  /// （其余字段传 null 表示保持原值）。
  TrackTags copyWith({
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    String? composer,
    String? genre,
    String? lyrics,
    String? coverMime,
    int? trackNumber,
    int? discNumber,
    int? year,
    int? durationMs,
    Object? coverBytes = _unset,
    bool? hasCover,
  }) {
    return TrackTags(
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      albumArtist: albumArtist ?? this.albumArtist,
      composer: composer ?? this.composer,
      genre: genre ?? this.genre,
      lyrics: lyrics ?? this.lyrics,
      coverMime: coverMime ?? this.coverMime,
      trackNumber: trackNumber ?? this.trackNumber,
      discNumber: discNumber ?? this.discNumber,
      year: year ?? this.year,
      durationMs: durationMs ?? this.durationMs,
      coverBytes: identical(coverBytes, _unset)
          ? this.coverBytes
          : coverBytes as Uint8List?,
      hasCover: hasCover ?? this.hasCover,
    );
  }

  /// 从原生读取 JSON 构造；容忍缺失字段。
  static TrackTags fromJson(Map<String, dynamic> json) {
    Uint8List? cover;
    final coverB64 = _asString(json['coverBase64']);
    if (coverB64.isNotEmpty) {
      try {
        cover = base64Decode(coverB64);
      } catch (_) {
        // base64 损坏：按无封面处理。
        cover = null;
      }
    }
    final hasCover = _asBool(json['hasCover']) || cover != null;
    return TrackTags(
      title: _asString(json['title']),
      artist: _asString(json['artist']),
      album: _asString(json['album']),
      albumArtist: _asString(json['albumArtist']),
      composer: _asString(json['composer']),
      genre: _asString(json['genre']),
      lyrics: _asString(json['lyrics']),
      coverMime: _asString(json['coverMime']),
      trackNumber: _asInt(json['trackNumber']),
      discNumber: _asInt(json['discNumber']),
      year: _asInt(json['year']),
      durationMs: _asInt(json['durationMs']),
      coverBytes: cover,
      hasCover: hasCover,
    );
  }

  /// 构造写入 JSON。所有受管字段一并写出（数字为 int，字符串可为空）。
  /// [coverSet] 为 true 时：有封面则写 `coverMime` + `coverBase64`，
  /// `coverBytes` 为 null 则写空 `coverBase64`（清除封面）。
  Map<String, Object?> toWriteJson({required bool coverSet}) {
    final out = <String, Object?>{
      'title': title,
      'artist': artist,
      'album': album,
      'albumArtist': albumArtist,
      'composer': composer,
      'genre': genre,
      'trackNumber': trackNumber,
      'discNumber': discNumber,
      'year': year,
      'lyrics': lyrics,
      'coverSet': coverSet,
    };
    if (coverSet) {
      final bytes = coverBytes;
      if (bytes != null) {
        out['coverMime'] = coverMime;
        out['coverBase64'] = base64Encode(bytes);
      } else {
        out['coverBase64'] = '';
      }
    }
    return out;
  }

  static String _asString(Object? v) => v?.toString() ?? '';

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static bool _asBool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v == 'true' || v == '1';
    return false;
  }
}

/// 读取本地文件标签。失败抛 [TagEditorException]。
Future<TrackTags> readTrackTags(String filePath) async {
  if (filePath.isEmpty) throw TagEditorException('empty file path');
  final json = await Isolate.run(() {
    try {
      return ScraperBindings.instance.readTagsJson(filePath);
    } finally {
      ScraperBindings.release();
    }
  });
  if (json.isEmpty) throw TagEditorException('read failed');
  final map = jsonDecode(json) as Map<String, dynamic>;
  if (map['ok'] != true) {
    throw TagEditorException(map['error']?.toString() ?? 'read failed');
  }
  return TrackTags.fromJson(map);
}

/// 写入本地文件标签。[coverSet] 为 true 时按 tags.coverBytes/coverMime 覆盖封面
/// （coverBytes 为 null 则清除封面）。失败抛 [TagEditorException]。
Future<void> writeTrackTags(
  String filePath,
  TrackTags tags, {
  required bool coverSet,
}) async {
  if (filePath.isEmpty) throw TagEditorException('empty file path');
  final tagsJson = jsonEncode(tags.toWriteJson(coverSet: coverSet));
  final json = await Isolate.run(() {
    try {
      return ScraperBindings.instance.writeTagsJson(filePath, tagsJson);
    } finally {
      ScraperBindings.release();
    }
  });
  if (json.isEmpty) throw TagEditorException('write failed');
  final map = jsonDecode(json) as Map<String, dynamic>;
  if (map['ok'] != true) {
    throw TagEditorException(map['error']?.toString() ?? 'write failed');
  }
}
