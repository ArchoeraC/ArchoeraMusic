// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌曲评论弹窗（NT对齐原项目 Comments.vue 核心交互；KG走
/// mcomment commentsv2/getCommentWithLike）。
///
/// 入口 [showCommentDialog]：NT源先 [NeteaseApi.findNeteaseCommentId]
/// 匹配NT歌曲 id（异源走云搜索），再分「热门 / 最新」两 Tab 分页拉取；
/// KG源直接用歌曲 hash 拉KG评论（无 Tab）。触底自动加载下一页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/kugou/kugou_api.dart';
import '../../services/netease/comment.dart';
import '../../services/netease/netease_api.dart';
import '../../services/netease/track.dart';
import '../../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../common/glass_surface.dart';
import 'netease_login_dialog.dart';
import '../player/s_controls.dart';
import '../common/toast.dart';

part 'comment_dialog/comment_dialog_actions.dart';
part 'comment_dialog/comment_dialog_view.dart';

/// KG评论 → 弹窗通用展示模型（字段与 NeteaseComment 对齐）。
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

/// 打开歌曲评论弹窗。
Future<void> showCommentDialog(BuildContext context, {required Track track}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    barrierDismissible: true,
    builder: (_) => CommentDialog(track: track),
  );
}

/// 评论弹窗主体。
class CommentDialog extends ConsumerStatefulWidget {
  const CommentDialog({super.key, required this.track});

  final Track track;

  @override
  ConsumerState<CommentDialog> createState() => _CommentDialogState();
}

class _CommentDialogState extends ConsumerState<CommentDialog> {
  /// 累计评论条数上限：超出截断并停止触底加载（防长回复列表撑爆内存）。
  static const _maxComments = 400;

  /// 匹配到的NT歌曲 id（null = 匹配中/失败）。
  String? _songId;

  /// 当前 Tab：true = 热门。
  bool _hot = true;

  NeteaseCommentPage? _page;
  bool _loading = true;
  bool _failed = false;
  final ScrollController _scroll = ScrollController();

  /// 发送评论输入框（仅NT源显示；KG发送接口需签名鉴权，未接入）。
  final TextEditingController _input = TextEditingController();
  bool _sending = false;

  NeteaseApi get _api => ref.read(neteaseApiProvider);

  /// 是否KG源（直接按歌曲 hash 拉KG评论，无 Tab、无需登录）。
  bool get _isKugou => widget.track.source == 'kugou';

  @override
  void initState() {
    super.initState();
    _match();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildCommentDialog(context);
}
