/// 网易云 API 传输层：`call(name, params)` 返回网易云原始响应体
/// （`{result: {...}}` / `{data: [...]}`），由 [NeteaseApi] 统一解析。
///
/// 实现：`ApisNeteaseCaller`（纯 Dart 直连，apis 包全量移植，不经侧车）。
///
/// 大文件拆分：业务域按 mixin 拆到 part 文件（搜索 / 登录会话 / 发现推荐 /
/// 歌单收藏 / 歌曲评论），本文件保留核心传输层与跨域方法 [resolvePlayUrl]。
library;

import 'dart:math' as math;

import '../../apis/lyric/types.dart';
import '../../apis/lyric/utils.dart';
import '../../apis/netease/api.dart' show nmClearNeteaseCookies;
import 'comment.dart';
import 'track.dart';

part 'netease_auth_api.dart';
part 'netease_comment_api.dart';
part 'netease_discover_api.dart';
part 'netease_playlist_api.dart';
part 'netease_search_api.dart';

abstract class NeteaseCaller {
  Future<Map<String, dynamic>?> call(String name, Map<String, dynamic> params);
}

/// 网易云接口业务异常（code != 200 等；对齐原项目 NeteaseApiError）。
class NeteaseApiError implements Exception {
  NeteaseApiError(this.message, [this.body]);

  final String message;
  final Map<String, dynamic>? body;

  @override
  String toString() => message;
}

/// 搜索结果（对齐原项目 apis/search 的 `SearchResult<T>`）。
class SearchResult<T> {
  const SearchResult({
    required this.items,
    required this.total,
    required this.hasMore,
  });

  final List<T> items;
  final int total;
  final bool hasMore;
}

/// 封面卡片（专辑 / 歌手 / 歌单搜索结果，对齐原项目 `CoverItem`）。
class CoverItem {
  const CoverItem({
    required this.id,
    required this.title,
    this.cover,
    this.subtitle = '',
    this.trackCount = 0,
  });

  final String id;
  final String title;
  final String? cover;
  final String subtitle;
  final int trackCount;
}

/// 音质档位 → 网易云 song_url level 参数（对齐原项目 NETEASE_LEVEL）。
const neteaseLevels = <String, String>{
  'lq': 'standard',
  'sq': 'higher',
  'hq': 'exhigh',
  'lossless': 'lossless',
  'hi-res': 'hires',
};

/// 网易云 API 核心：传输层 + 业务域 mixin 的公共基类。
///
/// 业务域 mixin 的 superclass 约束指向本类（避免 `class A with M on A`
/// 形成循环接口）；最终对外类型是 [NeteaseApi]。
class NeteaseApiBase {
  NeteaseApiBase(NeteaseCaller caller) : _caller = caller;

  final NeteaseCaller _caller;

  Future<Map<String, dynamic>?> _call(
    String name,
    Map<String, dynamic> params,
  ) => _caller.call(name, params);
}

/// 网易云 API 封装：解析 + 业务方法，传输层由 [NeteaseCaller] 决定
/// （侧车 RPC 或 Dart 原生直连）。
///
/// 对应原项目 `src/apis/search/netease.ts` + `src/apis/song/netease.ts`；
/// caller 返回网易云原始响应体（`{result: {...}}` / `{data: [...]}`）。
///
/// 业务域以 mixin 混合进本类：
/// - [NeteaseSearchApi]：cloudsearch 搜索（歌曲/专辑/歌手/歌单）
/// - [NeteaseAuthApi]：登录会话（login_status / 二维码 / 登出）
/// - [NeteaseDiscoverApi]：发现推荐（主页个性化/每日推荐/热门歌手/新碟）
/// - [NeteasePlaylistApi]：我喜欢 / 歌单 / 专辑·歌手收藏
/// - [NeteaseCommentApi]：歌曲评论
class NeteaseApi extends NeteaseApiBase
    with
        NeteaseSearchApi,
        NeteaseAuthApi,
        NeteaseDiscoverApi,
        NeteasePlaylistApi,
        NeteaseCommentApi {
  NeteaseApi(super.caller);

  /// 解析网易云 Track 的可播放 URL（song_url，对齐 resolveNeteaseUrl）。
  ///
  /// [quality] 为档位键（lq/sq/hq/lossless/hi-res），默认 hq（对齐原项目
  /// 默认 songLevel）。按用户偏好从高到低**自动降级**（如 lossless 失败 →
  /// hq → sq → lq），并**拒绝试听片段**（freeTrialInfo 非空 = 60s 试听，
  /// 对齐 SPlayer-Next fetchNeteasePlaySource 的 freeTrialInfo 过滤）。
  /// 全部档位失败 / VIP / 无版权时返回 null。
  Future<String?> resolvePlayUrl(String id, {String quality = 'hq'}) async {
    // 音质档位序（低 → 高）；从用户偏好档位开始向下降级尝试
    const order = ['lq', 'sq', 'hq', 'lossless', 'hi-res'];
    final start = order.indexOf(quality);
    if (start < 0) return null;
    for (var i = start; i >= 0; i--) {
      final q = order[i];
      try {
        final body = await _call('song_url', {
          'id': id,
          'level': neteaseLevels[q] ?? 'exhigh',
        });
        final data = body?['data'];
        if (data is! List || data.isEmpty) continue;
        final first = data.first;
        if (first is! Map<String, dynamic>) continue;
        final url = first['url']?.toString();
        if (url == null || url.isEmpty) continue;
        // 试听片段拒绝：非 VIP 账号 VIP 曲目返回带 freeTrialInfo 的 60s 片段
        final trial = first['freeTrialInfo'];
        if (trial != null && trial != false) continue;
        return url;
      } catch (_) {
        // 网络错误继续降级
      }
    }
    return null;
  }
}

/// 网易云登录账号（login_status profile 子集）。
class NeteaseAccount {
  const NeteaseAccount({
    required this.userId,
    required this.nickname,
    this.avatarUrl,
    this.vip = false,
  });

  final String userId;
  final String nickname;
  final String? avatarUrl;
  final bool vip;
}

/// 二维码登录轮询结果。
class NeteaseQrStatus {
  const NeteaseQrStatus({required this.code, required this.message});

  /// 801 待扫码 / 802 待确认 / 800 已过期 / 803 已确认。
  final int code;
  final String message;

  bool get scanned => code == 802;
  bool get expired => code == 800;
  bool get confirmed => code == 803;
}

/// 歌单详情（元信息 + 歌曲）。
class NeteasePlaylistDetail {
  const NeteasePlaylistDetail({required this.meta, required this.tracks});

  final PlaylistItem? meta;
  final List<Track> tracks;
}
