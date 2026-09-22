// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌曲评论弹窗（**通用模板**）。
///
/// 弹窗本身不含任何具体平台分支：所有源差异（目标 id 解析、登录门槛、
/// 分页 / 热门 Tab、发表 / 回复 / 删除能力、展示名）由 [CommentPlatform]
/// 注册项提供（见 `widgets/dialogs/comment_platform.dart`）。**新增音源 =
/// 实现一个 [CommentPlatform] 并注册**，本文件与视图/动作均无需改动。
///
/// 入口 [showCommentDialog]；触底自动加载下一页，累计条数有上限。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/netease/comment.dart';
import '../../services/netease/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../common/glass_surface.dart';
import '../player/s_controls.dart';
import '../common/toast.dart';
import 'comment_platform.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'comment_dialog/comment_dialog_actions.dart';
part 'comment_dialog/comment_dialog_view.dart';

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

  /// 当前曲目对应的平台适配器（本弹窗唯一的平台相关入口）。
  late final CommentPlatform _platform = commentPlatformFor(
    widget.track.source,
  );

  /// 解析出的评论目标 id（null = 解析中/失败）。
  String? _songId;

  /// 当前 Tab：true = 热门（仅 [CommentPlatform.supportsHot] 时显示）。
  bool _hot = true;

  NeteaseCommentPage? _page;
  bool _loading = true;
  bool _failed = false;
  final ScrollController _scroll = ScrollController();

  /// 发送评论输入框（[CommentPlatform.supportsSend] 时显示）。
  final TextEditingController _input = TextEditingController();
  bool _sending = false;

  /// 正在回复的目标（[CommentPlatform.supportsReply] 时可用；null = 发表新楼层）。
  NeteaseComment? _replyTo;

  /// 输入框焦点（点「回复」后自动聚焦）。
  final FocusNode _inputFocus = FocusNode();

  /// 是否支持发布评论。
  bool get _canSend => _platform.supportsSend;

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
    _inputFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildCommentDialog(context);
}
