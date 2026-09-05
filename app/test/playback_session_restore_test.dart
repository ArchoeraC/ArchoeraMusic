library;

import 'dart:convert';
import 'dart:io';

import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 冷启动断点续播回归：会话恢复（restore）的「自动续播快照保护」语义。
///
/// 背景（2026-09-05 修复实录）：restore 先把现场恢复为暂停展示态再异步启动
/// 引擎，中间态会被落盘为 `playing=false`。若冷启动续播因瞬时原因失败
/// （登录态/网络/源文件暂不可达），降级快照永久保留 → 之后每次冷启动都不再
/// 自动续播（「断点续播失效」）。本测试锁定：
///   - 自动续播失败时磁盘快照不得降级（仍为 playing=true@原位置，下次可重试）；
///   - 源解析失败（无引擎路径）同样不降级；
///   - 尾部记忆边界：保存位置已到/越过曲尾（带完整时长）时按从头恢复；
///   - 恢复期 pause 写盘被改写为可续播快照，解除后（stop）正常落盘 paused。
///
/// 执行方式（对齐 playback_session_test）：数据目录经 ARCHOERA_DATA_DIR 隔离，
/// 未设置时跳过（避免误写真实用户数据目录）。
final String? _dataDir = Platform.environment['ARCHOERA_DATA_DIR'];

Directory _setupDataDir() {
  final env = _dataDir;
  if (env == null) throw StateError('未设置 ARCHOERA_DATA_DIR，无法隔离测试数据');
  final dir = Directory(env);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

void _writePrefs(Directory dir, {bool autoPlay = true}) {
  File('${dir.path}/prefs.json').writeAsStringSync(
    jsonEncode({
      'audio.engine': 'stable',
      'player.sessionMemory': true,
      'player.autoPlayOnLaunch': autoPlay,
      'history.enabled': false,
    }),
  );
}

Track _localTrack(String id, String path, {int duration = 0}) => Track(
  id: id,
  title: 'T$id',
  artists: const [TrackArtist(name: 'tester')],
  source: 'local',
  localPath: path,
  duration: duration,
);

void main() {
  final skipReason = _dataDir == null ? '需设置 ARCHOERA_DATA_DIR 隔离测试数据目录' : false;

  test(
    '自动续播失败不得把磁盘快照降级为 paused（下次冷启动仍自动续播）',
    () async {
      final dir = _setupDataDir();
      _writePrefs(dir);
      // 源不可达 → 引擎 pipeline 失败（有引擎路径）必然走失败收敛。
      final track = _localTrack('x', '${dir.path}/not-exist.wav');
      const posMs = 30000;
      const PlaybackSessionStore().save(
        PlaybackSnapshot.fromState(
          queue: [track],
          queueIndex: 0,
          position: const Duration(milliseconds: posMs),
          repeatMode: 'list',
          shuffle: false,
          quality: 'hq',
          playing: true,
          title: 'Tx',
          trackId: 'x',
          track: track,
          source: '${dir.path}/not-exist.wav',
        ),
      );

      final container = ProviderContainer();
      final notifier = container.read(playbackProvider.notifier);
      await notifier.restore();
      // 等待启动失败收敛（源不可达 → 引擎 create 失败经 50ms 轮询报错；
      // 无引擎库环境则 start 同步抛错、source 保持 null）。
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        final s = container.read(playbackProvider);
        final logs = s.logs;
        if (s.source == null ||
            logs.any((l) => l.contains('引擎错误') || l.contains('引擎退出'))) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final snap = const PlaybackSessionStore().load();
      expect(snap, isNotNull);
      expect(
        snap!.playing,
        isTrue,
        reason: '自动续播失败不应把落盘快照降级为 paused（否则以后冷启动永不自动续播）',
      );
      expect(snap.positionMs, posMs, reason: '恢复点不应被改写');

      await notifier.stop();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    },
    skip: skipReason,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    '源解析失败（无引擎路径）同样不降级可续播快照',
    () async {
      final dir = _setupDataDir();
      _writePrefs(dir);
      // source=local 但无 localPath → _resolveSource 返回 null（解析失败，
      // 引擎从未创建——覆盖 restore 无引擎终态分支）。
      final track = _localTrack('y', '');
      const posMs = 40000;
      const PlaybackSessionStore().save(
        PlaybackSnapshot.fromState(
          queue: [track],
          queueIndex: 0,
          position: const Duration(milliseconds: posMs),
          repeatMode: 'list',
          shuffle: false,
          quality: 'hq',
          playing: true,
          title: 'Ty',
          trackId: 'y',
          track: track,
          source: null,
        ),
      );

      final container = ProviderContainer();
      final notifier = container.read(playbackProvider.notifier);
      await notifier.restore();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final s = container.read(playbackProvider);
      expect(s.source, isNull, reason: '解析失败不应建立会话');
      final snap = const PlaybackSessionStore().load();
      expect(snap, isNotNull);
      expect(
        snap!.playing,
        isTrue,
        reason: '源解析失败的自动续播同样不得降级快照',
      );
      expect(snap.positionMs, posMs);

      await notifier.stop();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    },
    skip: skipReason,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    '暂停恢复（autoPlay 关）按现场落盘 paused（快照保护不介入）',
    () async {
      final dir = _setupDataDir();
      _writePrefs(dir, autoPlay: false); // 暂停恢复（无自动续播），保护不介入
      final track = _localTrack('z', '${dir.path}/any.wav');
      const PlaybackSessionStore().save(
        PlaybackSnapshot.fromState(
          queue: [track],
          queueIndex: 0,
          position: const Duration(seconds: 10),
          repeatMode: 'list',
          shuffle: false,
          quality: 'hq',
          playing: false,
          title: 'Tz',
          trackId: 'z',
          track: track,
          source: null,
        ),
      );
      final container = ProviderContainer();
      final notifier = container.read(playbackProvider.notifier);
      await notifier.restore();
      final snap = const PlaybackSessionStore().load();
      expect(snap, isNotNull);
      expect(snap!.playing, isFalse, reason: '暂停恢复按现场落盘 paused');
      await notifier.stop();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    },
    skip: skipReason,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    '尾部记忆边界：保存位置已到/越过曲尾（带完整时长）→ 按从头恢复',
    () async {
      final dir = _setupDataDir();
      _writePrefs(dir, autoPlay: false);
      // 暂停现场，位置 = 曲尾（duration 5000ms）。
      final track = _localTrack('tail', '${dir.path}/tail.wav', duration: 5000);
      const PlaybackSessionStore().save(
        PlaybackSnapshot.fromState(
          queue: [track],
          queueIndex: 0,
          position: const Duration(milliseconds: 5000),
          repeatMode: 'list',
          shuffle: false,
          quality: 'hq',
          playing: false,
          title: 'Ttail',
          trackId: 'tail',
          track: track,
          source: null,
        ),
      );
      final container = ProviderContainer();
      final notifier = container.read(playbackProvider.notifier);
      await notifier.restore();
      final s = container.read(playbackProvider);
      expect(
        s.position,
        Duration.zero,
        reason: '停点已到曲尾应视为从头（避免从 duration 起播立即 EOF）',
      );

      // 位置在曲尾之前则保留。
      const PlaybackSessionStore().save(
        PlaybackSnapshot.fromState(
          queue: [_localTrack('mid', '${dir.path}/mid.wav', duration: 100000)],
          queueIndex: 0,
          position: const Duration(milliseconds: 65000),
          repeatMode: 'list',
          shuffle: false,
          quality: 'hq',
          playing: false,
          title: 'Tmid',
          trackId: 'mid',
          track: _localTrack('mid', '${dir.path}/mid.wav', duration: 100000),
          source: null,
        ),
      );
      await notifier.restore();
      final s2 = container.read(playbackProvider);
      expect(
        s2.position,
        const Duration(milliseconds: 65000),
        reason: '位置早于曲尾应保留恢复点',
      );
      await notifier.stop();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    },
    skip: skipReason,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
