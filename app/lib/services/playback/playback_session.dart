import 'dart:convert';
import 'dart:io';

import '../netease/track.dart';
import '../../stores/data_dir.dart';

/// 播放会话快照（仅记录关闭前的最后一次：队列 + 当前曲 + 位置 + 播放模式）。
///
/// 与播放历史（history.db，全量历史）不同：本快照是「恢复现场」用的单份
/// 状态，覆盖后即丢弃旧快照。序列化直接复用 [Track.toJson]/[Track.fromJson]。
class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.queue,
    required this.queueIndex,
    required this.positionMs,
    required this.repeatMode,
    required this.shuffle,
    required this.quality,
    this.playing = false,
    this.title,
    this.subtitle,
    this.trackId,
    this.track,
    this.source,
  });

  /// 播放队列（完整 Track 快照，恢复后直接可播）。
  final List<Track> queue;

  /// 当前曲目在队列中的索引（-1 = 无当前曲）。
  final int queueIndex;

  /// 上次播放位置（毫秒，恢复续播用）。
  final int positionMs;

  /// 播放模式（'list' / 'one'）。
  final String repeatMode;

  /// 随机播放开关。
  final bool shuffle;

  /// 当前音质档位（lq/sq/hq/lossless/hi-res）。
  final String quality;

  /// 关闭前是否在播放（恢复后决定自动续播或暂停展示）。
  final bool playing;

  /// 展示信息（播放条标题/副标题/曲目 id，快速恢复 UI 态）。
  final String? title;
  final String? subtitle;
  final String? trackId;

  /// 当前曲目（恢复续播用；队列可能为空但存在单曲播放）。
  final Track? track;

  /// 播放源（转码前解析后的 URL / 本地路径）。
  final String? source;

  /// 由当前播放状态生成快照。
  factory PlaybackSnapshot.fromState({
    required List<Track> queue,
    required int queueIndex,
    required Duration position,
    required String repeatMode,
    required bool shuffle,
    required String quality,
    required bool playing,
    String? title,
    String? subtitle,
    String? trackId,
    Track? track,
    String? source,
  }) {
    return PlaybackSnapshot(
      queue: List.of(queue),
      queueIndex: queueIndex,
      positionMs: position.inMilliseconds,
      repeatMode: repeatMode,
      shuffle: shuffle,
      quality: quality,
      playing: playing,
      title: title,
      subtitle: subtitle,
      trackId: trackId,
      track: track,
      source: source,
    );
  }

  Map<String, dynamic> toJson() => {
    'queue': queue.map((t) => t.toJson()).toList(),
    'queueIndex': queueIndex,
    'positionMs': positionMs,
    'repeatMode': repeatMode,
    'shuffle': shuffle,
    'quality': quality,
    'playing': playing,
    'title': title,
    'subtitle': subtitle,
    'trackId': trackId,
    'track': track?.toJson(),
    'source': source,
  };

  factory PlaybackSnapshot.fromJson(Map<String, dynamic> json) {
    final trackJson = json['track'];
    return PlaybackSnapshot(
      queue:
          (json['queue'] as List?)
              ?.whereType<Map>()
              .map((e) => Track.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          const [],
      queueIndex: (json['queueIndex'] as num?)?.toInt() ?? -1,
      positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
      repeatMode: json['repeatMode']?.toString() ?? 'list',
      shuffle: json['shuffle'] == true,
      quality: json['quality']?.toString() ?? 'hq',
      playing: json['playing'] == true,
      title: json['title']?.toString(),
      subtitle: json['subtitle']?.toString(),
      trackId: json['trackId']?.toString(),
      track: trackJson is Map
          ? Track.fromJson(Map<String, dynamic>.from(trackJson))
          : null,
      source: json['source']?.toString(),
    );
  }

  /// 队列中正在播放的曲目（未在队列时回退 track 字段）。
  Track? get currentTrack {
    if (queueIndex >= 0 && queueIndex < queue.length) {
      return queue[queueIndex];
    }
    return track;
  }
}

/// 播放会话快照持久化（JSON 文件 `last_session.json`，覆盖式写入）。
class PlaybackSessionStore {
  const PlaybackSessionStore();

  /// 快照文件路径：数据目录（`~/.local/share/ArchoeraMusic`）。
  static String get filePath => '${resolveDataDir()}/last_session.json';

  /// 写入快照（覆盖旧快照；失败静默，不影响播放主流程）。
  void save(PlaybackSnapshot snapshot) {
    try {
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(snapshot.toJson()),
      );
    } catch (_) {
      // 持久化失败不阻塞（自用项目，现场丢失可接受）
    }
  }

  /// 清除本地快照（关闭「会话记忆」时调用，避免残留旧现场）。
  void clear() {
    try {
      final file = File(filePath);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 清理失败静默
    }
  }

  /// 读取最近一次快照；无快照 / 损坏时返回 null。
  PlaybackSnapshot? load() {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map<String, dynamic>) return null;
      final snapshot = PlaybackSnapshot.fromJson(json);
      // 无任何可恢复内容视为无效快照
      if (snapshot.queue.isEmpty && snapshot.track == null) return null;
      return snapshot;
    } catch (_) {
      return null;
    }
  }
}
