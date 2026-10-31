// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili 音频取流（`/x/player/wbi/playurl`）。
///
/// 音轨范围（全部为音频，不涉及视频流）：
/// - `dash.audio`：AAC（64K / 132K / 192K，`mp4a`）；
/// - `dash.flac.audio`：Hi-Res 无损（`fLaC`，需大会员且稿件提供）；
/// - `dash.dolby.audio`：杜比全景声（`ec-3`，需大会员且稿件提供）。
///
/// 只使用服务端按账号权限实际返回的音频轨，不构造/伪造直链，不绕过付费墙；
/// 服务端返回 `is_preview=1` 时一律按不可用处理。
///
/// **播放器只接收音频 URL**：`dash.video`（以及旧版 `durl`）从不读取，
/// 即使响应里同时包含视频流也不会进入选集、播放或下载链路。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/request.dart';
import '../core/types.dart';

/// 音轨类别（决定回退顺序与落盘品质标识）。
enum BilibiliAudioKind { aac, flac, dolby }

Future<BilibiliAudioStream> bilibiliPlayUrl(
  BilibiliRequest request, {
  required String bvid,
  required String cid,
  required String quality,
}) async {
  if (!isBilibiliBvid(bvid) || cid.isEmpty) {
    throw const BilibiliApiException(
      'Invalid Bilibili playback identity.',
      kind: BilibiliErrorKind.invalidRequest,
    );
  }
  final root = await request.getJson(
    '/x/player/wbi/playurl',
    signed: true,
    params: {
      'bvid': bvid,
      'cid': cid,
      // 272 = DASH(16) + 杜比音频(256)；只请求音频所需能力位，
      // 不请求 HDR / 4K / 8K / AV1 等视频档位。响应中的 dash.video 一律忽略。
      'fnval': '272',
      'fnver': '0',
      'fourk': '0',
    },
  );
  final data = bilibiliData(root);
  final preview = data['is_preview'];
  if (preview == true || (preview is num && preview.toInt() == 1)) {
    throw const BilibiliApiException(
      'Bilibili offers only a preview for this video.',
      kind: BilibiliErrorKind.unavailable,
    );
  }

  final stream = selectBilibiliAudioFromDash(
    data['dash'],
    quality: quality,
  );
  if (stream == null) {
    throw const BilibiliApiException(
      'No supported Bilibili audio stream is available.',
      kind: BilibiliErrorKind.unavailable,
    );
  }
  return stream;
}

/// 从 playurl 响应的 `dash` 对象解析并挑选音轨（纯函数，便于单测）。
///
/// 只使用响应中实际存在的音轨；无权限时对应字段通常缺失 / 为空。
@visibleForTesting
BilibiliAudioStream? selectBilibiliAudioFromDash(
  Object? dash, {
  required String quality,
}) {
  final aac = <_AudioCandidate>[];
  final flac = <_AudioCandidate>[];
  final dolby = <_AudioCandidate>[];

  void collect(Object? raw, BilibiliAudioKind kind) {
    if (raw is Map) raw = [raw];
    if (raw is! List) return;
    for (final entry in raw) {
      if (entry is! Map) continue;
      final row = Map<String, dynamic>.from(entry);
      final codecs = row['codecs']?.toString() ?? '';
      final lower = codecs.toLowerCase();
      final matches = switch (kind) {
        BilibiliAudioKind.aac => lower.startsWith('mp4a'),
        BilibiliAudioKind.flac => lower == 'flac',
        BilibiliAudioKind.dolby =>
          lower.startsWith('ec-3') ||
              lower.startsWith('eac3') ||
              lower.startsWith('ac-3'),
      };
      if (!matches) continue;
      final url = bilibiliHttpsUrl(row['baseUrl'] ?? row['base_url']);
      if (url == null) continue;
      final backups = <String>[];
      final rawBackups = row['backupUrl'] ?? row['backup_url'];
      if (rawBackups is List) {
        for (final backup in rawBackups) {
          final normalized = bilibiliHttpsUrl(backup);
          if (normalized != null && normalized != url) backups.add(normalized);
        }
      }
      final candidate = _AudioCandidate(
        id: _asInt(row['id']) ?? 0,
        bandwidth: _asInt(row['bandwidth']) ?? 0,
        url: url,
        backups: backups,
        size: _asInt(row['size']),
        kind: kind,
        codec: kind == BilibiliAudioKind.flac
            ? 'flac'
            : kind == BilibiliAudioKind.dolby
            ? 'eac3'
            : 'aac',
      );
      switch (kind) {
        case BilibiliAudioKind.aac:
          aac.add(candidate);
        case BilibiliAudioKind.flac:
          flac.add(candidate);
        case BilibiliAudioKind.dolby:
          dolby.add(candidate);
      }
    }
  }

  if (dash is Map) {
    collect(dash['audio'], BilibiliAudioKind.aac);
    final rawFlac = dash['flac'];
    if (rawFlac is Map) collect(rawFlac['audio'], BilibiliAudioKind.flac);
    final rawDolby = dash['dolby'];
    if (rawDolby is Map) collect(rawDolby['audio'], BilibiliAudioKind.dolby);
  }
  final chosen = _pickAudio(
    quality: quality,
    aac: aac,
    flac: flac,
    dolby: dolby,
  );
  if (chosen == null) return null;

  // 优先 API 返回的 upos 直连 CDN（边缘中转节点在部分网络下会卡住）。
  final allUrls = <String>[chosen.url, ...chosen.backups];
  final preferred = allUrls.firstWhere(_isDirectUpos, orElse: () => chosen.url);
  if (preferred != chosen.url) {
    final index = allUrls.indexOf(preferred);
    if (index > 0) {
      allUrls
        ..removeAt(index)
        ..insert(0, preferred);
    }
  }

  final deadline = _deadlineOf(preferred);
  return BilibiliAudioStream(
    url: preferred,
    qualityId: chosen.id,
    bandwidth: chosen.bandwidth,
    backups: allUrls.skip(1).toList(growable: false),
    deadline: deadline,
    fileSize: chosen.size,
    codec: chosen.codec,
    isLossless: chosen.kind == BilibiliAudioKind.flac,
  );
}

/// 按统一音质档挑选音轨：
/// - lq / sq / hq：AAC 对应档位（缺档时取不高于目标的最高档）；
/// - lossless / hi-res：FLAC → 杜比 → 192K AAC（按实际可用权限回退）。
_AudioCandidate? _pickAudio({
  required String quality,
  required List<_AudioCandidate> aac,
  required List<_AudioCandidate> flac,
  required List<_AudioCandidate> dolby,
}) {
  final premium = [...flac, ...dolby]
    ..sort((a, b) {
      if (a.kind != b.kind) {
        return a.kind == BilibiliAudioKind.flac ? -1 : 1;
      }
      return b.bandwidth.compareTo(a.bandwidth);
    });
  if (quality == 'lossless' || quality == 'hi-res') {
    if (premium.isNotEmpty) return premium.first;
  }

  final target = switch (quality) {
    'lq' => 30216,
    'sq' => 30232,
    _ => 30280,
  };
  final eligible = aac.where((c) => c.id <= target).toList()
    ..sort((a, b) {
      final byId = a.id.compareTo(b.id);
      return byId != 0 ? byId : a.bandwidth.compareTo(b.bandwidth);
    });
  if (eligible.isNotEmpty) return eligible.last;
  if (aac.isNotEmpty) {
    // 目标档位缺失（例如只有 192K）：取现有 AAC 中最高的一档。
    return aac.reduce((a, b) => a.bandwidth >= b.bandwidth ? a : b);
  }
  return premium.isEmpty ? null : premium.first;
}

bool _isDirectUpos(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  return host.startsWith('upos-') && host.endsWith('.bilivideo.com');
}

int? _deadlineOf(String url) {
  final raw = Uri.tryParse(url)?.queryParameters['deadline'];
  return raw == null ? null : int.tryParse(raw);
}

int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

class _AudioCandidate {
  const _AudioCandidate({
    required this.id,
    required this.bandwidth,
    required this.url,
    required this.backups,
    required this.size,
    required this.kind,
    required this.codec,
  });

  final int id;
  final int bandwidth;
  final String url;
  final List<String> backups;
  final int? size;
  final BilibiliAudioKind kind;
  final String codec;
}
