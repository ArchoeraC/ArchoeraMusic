// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌曲评论「平台注册表」。
///
/// 评论弹窗（[CommentDialog]）是**通用模板**：它只面向本文件的
/// [CommentPlatform] 接口，不含任何具体平台分支。新增一个音源的评论支持 =
/// 实现一个 [CommentPlatform] 并放进 [_registry]，弹窗无需改动。
///
/// 每个适配器负责该源的差异：
/// - 目标 id 解析（含「需要登录」时的引导）；
/// - 分页拉取与「热门/最新」能力；
/// - 是否支持发表 / 回复 / 删除，以及对应调用；
/// - 平台展示名（未找到评论 / 需登录提示）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/kugou/kugou_api.dart';
import '../../services/neko/neko_types.dart';
import '../../services/netease/comment.dart';
import '../../services/netease/netease_api.dart';
import '../../services/netease/track.dart';
import '../../stores/providers.dart';
import '../common/toast.dart';
import 'neko_login_dialog.dart';
import 'netease_login_dialog.dart';
import 'qqmusic_login_dialog.dart';

/// 平台操作的可直接展示异常（消息已本地化）。弹窗原样 toast，不再套「发送失败：」。
class CommentOperationException implements Exception {
  CommentOperationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 单个音源的评论适配器。新增平台实现本类并注册即可。
abstract class CommentPlatform {
  /// 平台标识（与 `Track.source` 对齐）。
  String get source;

  /// 平台展示名（未找到评论 / 需登录提示用；本地化）。
  String label(AppLocalizations l10n);

  /// 是否提供「热门 / 最新」两 Tab（NT、QQ）。
  bool get supportsHot => false;

  /// 是否支持发表评论（NT、NK）。
  bool get supportsSend => false;

  /// 是否支持回复（NK）。
  bool get supportsReply => false;

  /// 是否支持删除（NK）。
  bool get supportsDelete => false;

  /// 是否把楼内回复展开为独立条目并带操作（NK）。false = 只展示第一条引用。
  bool get expandsReplies => false;

  /// 解析评论目标 id；null = 不可评论（弹窗显示「未找到」）。
  Future<String?> resolveTarget(
    BuildContext context,
    WidgetRef ref,
    Track track,
  );

  /// 拉取一页评论。
  Future<NeteaseCommentPage> fetchPage(
    WidgetRef ref,
    String targetId, {
    required bool hot,
    required int page,
  });

  /// 发表 / 回复（仅 [supportsSend]）；返回 false = 未发送（未登录等，已自行提示）。
  Future<bool> send(
    BuildContext context,
    WidgetRef ref,
    String targetId,
    String content, {
    String? parentId,
  }) async => false;

  /// 删除（仅 [supportsDelete]）。
  Future<void> delete(WidgetRef ref, String commentId) async {}
}

/// 按 `Track.source` 取适配器；未注册源回退 NT（历史行为：异源走 NT 云搜索匹配）。
CommentPlatform commentPlatformFor(String source) =>
    _registry[source] ?? _registry['netease']!;

final Map<String, CommentPlatform> _registry = {
  for (final p in <CommentPlatform>[
    _NeteaseCommentPlatform(),
    _KugouCommentPlatform(),
    _QqCommentPlatform(),
    _NekoCommentPlatform(),
  ])
    p.source: p,
};

// ── NT ─────────────────────────────────────────────────────────────────

class _NeteaseCommentPlatform extends CommentPlatform {
  @override
  String get source => 'netease';

  @override
  String label(AppLocalizations l10n) => l10n.brandNetease;

  @override
  bool get supportsHot => true;

  @override
  bool get supportsSend => true;

  @override
  Future<String?> resolveTarget(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) => ref.read(neteaseApiProvider).findNeteaseCommentId(track);

  @override
  Future<NeteaseCommentPage> fetchPage(
    WidgetRef ref,
    String targetId, {
    required bool hot,
    required int page,
  }) {
    final api = ref.read(neteaseApiProvider);
    return hot
        ? api.songHotComments(targetId, page: page)
        : api.songComments(targetId, page: page);
  }

  @override
  Future<bool> send(
    BuildContext context,
    WidgetRef ref,
    String targetId,
    String content, {
    String? parentId,
  }) async {
    final l10n = context.l10n;
    if (ref.read(neteaseAuthProvider) == null) {
      toast(l10n.commentLoginRequired(platform: l10n.brandNetease));
      await showNeteaseLoginDialog(context);
      return false;
    }
    try {
      await ref.read(neteaseApiProvider).sendComment(targetId, content);
      return true;
    } on NeteaseApiError catch (e) {
      // 505：重复内容，直接用更贴切的文案。
      if (e.body?['code'] == 505) {
        throw CommentOperationException(l10n.commentDuplicate);
      }
      rethrow;
    }
  }
}

// ── KG ─────────────────────────────────────────────────────────────────

/// KG评论 → 通用展示模型（字段与 [NeteaseComment] 对齐）。
NeteaseComment _kgToTile(KugouComment c) => NeteaseComment(
  id: c.id,
  userName: c.userName,
  avatar: c.avatar,
  text: c.text,
  location: c.location,
  likedCount: c.likedCount,
  replyTotal: c.replyTotal,
  time: c.timeMs,
  reply: c.reply.map(_kgToTile).toList(),
);

class _KugouCommentPlatform extends CommentPlatform {
  @override
  String get source => 'kugou';

  @override
  String label(AppLocalizations l10n) => l10n.brandKugou;

  @override
  Future<String?> resolveTarget(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    final hash = track.kugou?.hash;
    return (hash == null || hash.isEmpty) ? null : hash;
  }

  @override
  Future<NeteaseCommentPage> fetchPage(
    WidgetRef ref,
    String targetId, {
    required bool hot,
    required int page,
  }) async {
    final kp = await ref
        .read(kugouApiProvider)
        .songComments(targetId, page: page);
    return NeteaseCommentPage(
      list: kp.list.map(_kgToTile).toList(),
      total: kp.total,
      page: kp.page,
      limit: kp.limit,
    );
  }
}

// ── QQ ─────────────────────────────────────────────────────────────────

class _QqCommentPlatform extends CommentPlatform {
  @override
  String get source => 'qqmusic';

  @override
  String label(AppLocalizations l10n) => l10n.platformQQMusic;

  @override
  bool get supportsHot => true;

  @override
  Future<String?> resolveTarget(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    final mid = track.qqmusic?.mid.isNotEmpty == true
        ? track.qqmusic!.mid
        : track.id;
    if (mid.isEmpty) return null;
    // 官方读取需登录态：未登录先引导，取消则视为不可评论。
    if (!ref.read(qqMusicApiProvider).isLoggedIn) {
      final ok = await showQqMusicLoginDialog(context);
      if (ok != true) return null;
    }
    return mid;
  }

  @override
  Future<NeteaseCommentPage> fetchPage(
    WidgetRef ref,
    String targetId, {
    required bool hot,
    required int page,
  }) => ref
      .read(qqMusicApiProvider)
      .songComments(targetId, page: page, hot: hot);
}

// ── NK ─────────────────────────────────────────────────────────────────

/// NK评论 → 通用展示模型（服务端不返回头像，走首字母占位）。
NeteaseComment _nekoToTile(NekoComment c) => NeteaseComment(
  id: c.id,
  userId: c.userId,
  userName: c.userName,
  text: c.text,
  location: c.location,
  replyTotal: c.replyTotal,
  time: c.time,
  canDelete: c.canDelete,
  replyToName: c.replyToName,
  reply: c.replies.map(_nekoToTile).toList(),
);

class _NekoCommentPlatform extends CommentPlatform {
  @override
  String get source => 'neko';

  @override
  String label(AppLocalizations l10n) => l10n.platformNeko;

  @override
  bool get supportsSend => true;

  @override
  bool get supportsReply => true;

  @override
  bool get supportsDelete => true;

  @override
  bool get expandsReplies => true;

  @override
  Future<String?> resolveTarget(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async => track.id.isEmpty ? null : track.id;

  @override
  Future<NeteaseCommentPage> fetchPage(
    WidgetRef ref,
    String targetId, {
    required bool hot,
    required int page,
  }) async {
    final p = await ref
        .read(nekoApiProvider)
        .songComments(targetId, page: page);
    return NeteaseCommentPage(
      list: p.list.map(_nekoToTile).toList(),
      total: p.total,
      page: p.page,
      limit: p.pageSize,
    );
  }

  @override
  Future<bool> send(
    BuildContext context,
    WidgetRef ref,
    String targetId,
    String content, {
    String? parentId,
  }) async {
    final l10n = context.l10n;
    if (!ref.read(nekoApiProvider).isLoggedIn) {
      toast(l10n.commentLoginRequired(platform: l10n.platformNeko));
      await showNekoLoginDialog(context);
      return false;
    }
    await ref
        .read(nekoApiProvider)
        .sendComment(targetId, content, parentId: parentId);
    return true;
  }

  @override
  Future<void> delete(WidgetRef ref, String commentId) =>
      ref.read(nekoApiProvider).deleteComment(commentId);
}
