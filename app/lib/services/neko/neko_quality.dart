// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 音质档位映射（纯函数，供播放 / 下载 / UI 复用）。
///
/// 服务端 `GET /api/music/file/{id}?quality=` 自「可选音质流」起只认四档
/// `standard` / `hq` / `sq` / `hires`（见 Neko 歌姬计划 API 文档 §音乐文件）：
///
/// - `standard`：128 kbps MP3 转码缓存；
/// - `hq`：320 kbps MP3 转码缓存；
/// - `sq`：原始无损音源（不升码）；
/// - `hires`：原始 Hi-Res 音源（最高档封顶）。
///
/// 本项目统一档位键为 `lq` / `sq` / `hq` / `lossless` / `hi-res`，故这里做
/// 显式映射；服务端无「较高」档，`sq` 归入 `hq`。`/api/music/info/{id}` 的
/// `maxQuality` 与请求参数同值域，[normalizeNekoQuality] 统一归一化。
library;

/// 统一档位键 → 服务端 `quality` 参数。
const nekoQualityParams = <String, String>{
  'lq': 'standard',
  'sq': 'hq',
  'hq': 'hq',
  'lossless': 'sq',
  'hi-res': 'hires',
};

/// 服务端档位排序（standard < hq < sq < hires），用于按 `maxQuality` 裁剪。
const nekoQualityRanks = <String, int>{
  'standard': 0,
  'hq': 1,
  'sq': 2,
  'hires': 3,
};

/// 统一档位键 → 服务端 `quality` 参数（未知档回退 `hq`，与服务端默认一致）。
String nekoQualityParam(String quality) => nekoQualityParams[quality] ?? 'hq';

/// 归一化服务端 `quality` / `maxQuality` 取值（含旧别名）→ 四档之一；
/// 无法识别 / 空 → null。
String? normalizeNekoQuality(String? raw) {
  final v = raw?.trim().toLowerCase() ?? '';
  return switch (v) {
    'standard' || 'lq' || '128' => 'standard',
    'hq' || 'mq' || '320' => 'hq',
    'sq' || 'lossless' || '无损' => 'sq',
    'hires' || 'hi-res' || 'hi_res' => 'hires',
    _ => null,
  };
}

/// 服务端档位排序值（未知 / 空按 `hq`，与服务端 `qualityRank` 缺省一致）。
int nekoQualityRank(String? serverQuality) =>
    nekoQualityRanks[normalizeNekoQuality(serverQuality)] ?? 1;

/// Neko 播放页可选档位（统一档位键）：服务端四档去重后的
/// `lq`/`hq`/`lossless`/`hi-res`，并按 [maxQuality] 裁剪（只保留不超过实际
/// 最高档的档位）。
///
/// [maxQuality] 为 null / 无法识别（未升级、离线、字段缺失）时返回全档位；
/// 实际取流时服务端仍会按原始最高音质封顶。
List<String> nekoLevelsForMaxQuality(String? maxQuality) {
  const appLevels = ['lq', 'hq', 'lossless', 'hi-res'];
  final max = normalizeNekoQuality(maxQuality);
  if (max == null) return appLevels;
  final maxRank = nekoQualityRank(max);
  final capped = appLevels
      .where((l) => nekoQualityRank(nekoQualityParam(l)) <= maxRank)
      .toList(growable: false);
  return capped.isEmpty ? const ['lq'] : capped;
}

/// Neko `maxQuality` → 列表音质角标（`label` + 是否无损档）；
/// 未知 / 未取到 → null（列表不显示，避免误导）。
({String label, bool lossless})? nekoQualityBadge(String? maxQuality) {
  final max = normalizeNekoQuality(maxQuality);
  if (max == null) return null;
  return switch (nekoLevelsForMaxQuality(max).last) {
    'hi-res' => (label: 'Hi-Res', lossless: true),
    'lossless' => (label: 'Lossless', lossless: true),
    'hq' => (label: 'HQ', lossless: false),
    _ => (label: 'LQ', lossless: false),
  };
}
