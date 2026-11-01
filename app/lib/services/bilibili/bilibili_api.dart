// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili 音源门面：搜索 / 详情 / 分P / 取流 / 扫码登录。
///
/// - 协议层在 `apis/bilibili/`（纯 Dart 直连官方接口）；
/// - 登录 Cookie 经宿主 vault（平台键 `bilibili`）持久化；
/// - 只使用账号实际有权访问的 AAC 音轨，不请求付费墙之外的音质；
/// - 业务异常统一为 [BilibiliApiException]，由 SourcePlatform 适配器映射文案。
///
/// 协议参考：NextKde/KMusic 的 `docs/Bilibili*.md` 与社区公开端点资料；
/// 本目录为独立 Dart 实现，未复制其源码。
library;

import 'package:flutter/foundation.dart';

import '../../apis/bilibili/core/request.dart';
import '../../apis/bilibili/core/types.dart';
import '../../apis/bilibili/modules/login_qr.dart';
import '../../apis/bilibili/modules/playurl.dart';
import '../../apis/bilibili/modules/reply.dart';
import '../../apis/bilibili/modules/search.dart';
import '../../apis/bilibili/modules/view.dart';
import '../log/log.dart';
import '../netease/netease_api.dart' show SearchResult;
import '../netease/track.dart';

/// Bilibili 服务（ChangeNotifier：登录态/资料变化通知 UI）。
class BilibiliApi extends ChangeNotifier {
  BilibiliApi({BilibiliRequest? request})
    : _request = request ?? BilibiliRequest();

  final BilibiliRequest _request;
  BilibiliAccount? _profile;
  bool _profileLoading = false;

  BilibiliAccount? get profile => _profile;

  bool get isLoggedIn => _profile != null || _request.hasSession;

  /// 启动恢复：有 SESSDATA 时用 nav 核实身份；网络失败静默保持会话，
  /// 明确 `-101` 才清空本地会话。
  Future<void> loadProfileSilently() async {
    if (_profileLoading || !_request.hasSession) return;
    _profileLoading = true;
    try {
      await refreshProfile();
    } on BilibiliApiException catch (e) {
      if (e.kind == BilibiliErrorKind.authRequired) {
        _request.clearSession();
        _profile = null;
        notifyListeners();
      } else {
        Log.w('bilibili', '启动恢复账号失败（保留会话）: $e');
      }
    } catch (e) {
      Log.w('bilibili', '启动恢复账号异常（保留会话）: $e');
    } finally {
      _profileLoading = false;
    }
  }

  /// 强制刷新账号资料（登录成功 / 用户手动刷新）。
  Future<void> refreshProfile() async {
    if (!_request.hasSession) {
      _profile = null;
      notifyListeners();
      return;
    }
    final account = await bilibiliNav(_request);
    _profile = account;
    notifyListeners();
  }

  /// 本地退出：清空 vault 会话与内存资料（B 站无必须调用的登出 API）。
  void logout() {
    _request.clearSession();
    _profile = null;
    notifyListeners();
  }

  // ── 扫码登录 ─────────────────────────────────────────────────────────

  Future<BilibiliQrChallenge> qrGenerate() => bilibiliQrGenerate(_request);

  Future<BilibiliQrState> qrPoll(String key) async {
    final state = await bilibiliQrPoll(_request, key);
    if (state == BilibiliQrState.signedIn) {
      await refreshProfile();
    }
    return state;
  }

  // ── 搜索 / 详情 ─────────────────────────────────────────────────────

  /// 搜索视频；输入 BV 号或 B 站视频链接时按详情直接返回对应分P。
  Future<SearchResult<Track>> searchSongs(
    String keyword, {
    int page = 1,
    int limit = 20,
  }) async {
    final ref = _parseVideoRef(keyword);
    if (ref != null) {
      final detail = await detailByBvid(ref.bvid);
      final part = _partAtPage(detail.parts, ref.page ?? 1);
      return SearchResult(
        items: [trackForPart(detail, part)],
        total: 1,
        hasMore: false,
      );
    }
    final result = await bilibiliSearchVideos(
      _request,
      keyword,
      page: page,
      pageSize: limit,
    );
    return SearchResult(
      items: [for (final item in result.items) _trackFromItem(item)],
      total: result.total,
      hasMore: result.hasMore,
    );
  }

  Future<BilibiliVideoDetail> detailByBvid(String bvid) =>
      bilibiliVideoDetail(_request, bvid);

  Future<BilibiliVideoDetail> detailForTrack(Track track) {
    final bvid = track.bilibili?.bvid ?? _bvidFromId(track.id);
    if (bvid == null || !isBilibiliBvid(bvid)) {
      throw const BilibiliApiException(
        'Invalid Bilibili video identity.',
        kind: BilibiliErrorKind.invalidRequest,
      );
    }
    return detailByBvid(bvid);
  }

  Future<List<BilibiliPart>> partsFor(Track track) async =>
      (await detailForTrack(track)).parts;

  // ── 评论（只读） ─────────────────────────────────────────────────────

  /// 视频评论目标 id（评论接口使用 aid 而非 bvid）。
  Future<String?> commentTarget(Track track) async {
    final detail = await detailForTrack(track);
    return detail.aid > 0 ? '${detail.aid}' : null;
  }

  /// 视频评论一页；[next] 为上一页返回的游标（首页传 0）。
  Future<BilibiliCommentPage> videoComments(
    String aid, {
    required bool hot,
    int next = 0,
  }) => bilibiliVideoComments(_request, aid: aid, hot: hot, next: next);

  /// 搜索条目 → Track（P1 身份，cid 在播放/下载前补齐）。
  /// 搜索结果 → Track。
  Track _trackFromItem(BilibiliSearchItem item) {
    final cid = item.cid;
    final hasCid = cid != null && cid.isNotEmpty;
    return Track(
      id: hasCid ? '${item.bvid}:$cid' : item.bvid,
      title: item.title,
      artists: [if (item.author.isNotEmpty) TrackArtist(name: item.author)],
      duration: item.durationMs,
      cover: item.cover,
      source: 'bilibili',
      bilibili: BilibiliTrackInfo(
        bvid: item.bvid,
        cid: hasCid ? cid : null,
        pageTitle: null,
      ),
    );
  }

  /// 视频详情 + 分P → 稳定 Track（`bvid:cid` 作为队列/历史身份）。
  Track trackForPart(BilibiliVideoDetail detail, BilibiliPart part) {
    return Track(
      id: '${detail.bvid}:${part.cid}',
      title: detail.title,
      comment: part.title.isEmpty ? null : part.title,
      artists: [if (detail.owner.isNotEmpty) TrackArtist(name: detail.owner)],
      duration: part.durationMs > 0 ? part.durationMs : detail.durationMs,
      cover: detail.cover,
      source: 'bilibili',
      bilibili: BilibiliTrackInfo(
        bvid: detail.bvid,
        cid: '${part.cid}',
        pageTitle: part.title.isEmpty ? null : part.title,
      ),
    );
  }

  // ── 播放 / 下载 ─────────────────────────────────────────────────────

  /// 解析可播放 AAC 直链；分P身份缺失时自动取首P。
  Future<String> resolvePlayUrl(Track track, {required String quality}) async {
    final info = track.bilibili;
    final bvid = info?.bvid ?? _bvidFromId(track.id);
    if (bvid == null || !isBilibiliBvid(bvid)) {
      throw const BilibiliApiException(
        'Invalid Bilibili video identity.',
        kind: BilibiliErrorKind.invalidRequest,
      );
    }
    var cid = info?.cid;
    if (cid == null || cid.isEmpty) {
      final detail = await detailByBvid(bvid);
      cid = '${detail.parts.first.cid}';
    }
    final audio = await bilibiliPlayUrl(
      _request,
      bvid: bvid,
      cid: cid,
      quality: quality,
    );
    return audio.url;
  }

  /// 下载前补齐 cid，并统一为 `bvid:cid` 身份；Rust 原生解析器直接消费。
  Future<Track> prepareForDownload(Track track) async {
    final info = track.bilibili;
    final cid = info?.cid;
    if (info != null &&
        isBilibiliBvid(info.bvid) &&
        cid != null &&
        cid.isNotEmpty) {
      return track.copyWithBilibili(
        BilibiliTrackInfo(bvid: info.bvid, cid: cid, pageTitle: info.pageTitle),
        id: '${info.bvid}:$cid',
      );
    }
    final detail = await detailForTrack(track);
    return trackForPart(detail, detail.parts.first);
  }

  // ── 内部解析 ─────────────────────────────────────────────────────────

  static BilibiliPart _partAtPage(List<BilibiliPart> parts, int page) {
    if (parts.isEmpty) {
      throw const BilibiliApiException(
        'This Bilibili video has no playable parts.',
        kind: BilibiliErrorKind.unavailable,
      );
    }
    for (final part in parts) {
      if (part.page == page) return part;
    }
    return parts.first;
  }

  static String? _bvidFromId(String id) {
    final colon = id.indexOf(':');
    final bvid = colon >= 0 ? id.substring(0, colon) : id;
    return isBilibiliBvid(bvid) ? bvid : null;
  }

  static ({String bvid, int? page})? _parseVideoRef(String input) {
    final text = input.trim();
    if (isBilibiliBvid(text)) return (bvid: text, page: null);

    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    if (host != 'bilibili.com' &&
        host != 'www.bilibili.com' &&
        host != 'm.bilibili.com') {
      return null;
    }
    String? bvid;
    for (final segment in uri.pathSegments) {
      if (isBilibiliBvid(segment)) {
        bvid = segment;
        break;
      }
    }
    if (bvid == null) return null;
    final page = int.tryParse(uri.queryParameters['p'] ?? '');
    return (bvid: bvid, page: page == null || page < 1 ? null : page);
  }

  @override
  void dispose() {
    _request.dispose();
    super.dispose();
  }
}
