// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../comment_dialog.dart';

extension _CommentDialogView on _CommentDialogState {
  Widget _buildCommentDialog(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: GlassDialogSurface(
        radius: BorderRadius.circular(16),
        color: scheme.surfaceContainer,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CommentDialogHeader(trackTitle: widget.track.title, l10n: l10n),
              // NT 有「热门 / 最新」两 Tab；KG / NK 只有单一时间线。
              if (!_isKugou && !_isNeko)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: SSegmented<bool>(
                    options: [
                      SSegmentedOption(true, l10n.commentHot),
                      SSegmentedOption(false, l10n.commentLatest),
                    ],
                    selected: _hot,
                    onChanged: _switchTab,
                  ),
                ),
              const SizedBox(height: 8),
              const Divider(height: 1),
              Expanded(child: _buildListArea(scheme, l10n)),
              if (_canSend && _songId != null)
                _CommentInputBar(
                  controller: _input,
                  focusNode: _inputFocus,
                  sending: _sending,
                  replyToName: _replyTo?.userName,
                  onCancelReply: _cancelReply,
                  theme: theme,
                  scheme: scheme,
                  l10n: l10n,
                  onSend: _send,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildListArea(ColorScheme scheme, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final page = _page;
    final list = page?.list ?? const <NeteaseComment>[];
    final hasMore = _songId != null && page != null && page.hasMore;
    if (_songId == null) {
      if (_failed) {
        return _EmptyHint(
          icon: EtaIcons.cloudOutline,
          text: l10n.commentNotFound(
            platform: _isKugou
                ? l10n.brandKugou
                : _isQq
                ? l10n.platformQQMusic
                : _isNeko
                ? l10n.platformNeko
                : l10n.brandNetease,
          ),
        );
      }
      return const _CommentSpinner();
    }
    if (list.isEmpty) {
      return _loading
          ? const _CommentSpinner()
          : _EmptyHint(icon: EtaIcons.messageOutline, text: l10n.commentEmpty);
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      itemCount: list.length + (_loading || hasMore ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 48),
      itemBuilder: (context, index) {
        if (index >= list.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: _loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      l10n.commonNoMore,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
            ),
          );
        }
        return _CommentTile(
          comment: list[index],
          // 回复 / 删除仅在 NK 提供（服务端支持 parentId / canDelete）；
          // 其它平台传 null → 通用模板自动隐藏这些入口。
          onReply: _isNeko ? _startReply : null,
          onDelete: _isNeko ? _deleteNeko : null,
          renderReplies: _isNeko,
        );
      },
    );
  }
}

class _CommentDialogHeader extends StatelessWidget {
  const _CommentDialogHeader({required this.trackTitle, required this.l10n});

  final String trackTitle;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.commentTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  trackTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.commonClose,
            icon: const Icon(EtaIcons.close, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _CommentInputBar extends StatelessWidget {
  const _CommentInputBar({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.theme,
    required this.scheme,
    required this.l10n,
    required this.onSend,
    this.replyToName,
    this.onCancelReply,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final ThemeData theme;
  final ColorScheme scheme;
  final AppLocalizations l10n;
  final Future<void> Function() onSend;

  /// 非空 = 正在回复该用户（顶部显示「回复 @昵称」条；仅 NK 传值）。
  final String? replyToName;
  final VoidCallback? onCancelReply;

  @override
  Widget build(BuildContext context) {
    final replyTo = replyToName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (replyTo != null && replyTo.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Icon(EtaIcons.chatOutline, size: 15, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.commentReplyTo(user: replyTo),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  InkResponse(
                    onTap: onCancelReply,
                    radius: 14,
                    child: Icon(
                      EtaIcons.close,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: !sending,
                  maxLength: 500,
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    hintText: l10n.commentInputHint,
                    hintStyle: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    counterText: '',
                    isDense: true,
                    filled: true,
                    fillColor: scheme.surface.withValues(alpha: 0.6),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: l10n.commentSend,
                onPressed: sending ? null : onSend,
                icon: sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(EtaIcons.sendPlane, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CommentSpinner extends StatelessWidget {
  const _CommentSpinner();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    );
  }
}

/// 评论时间文案（楼层与回复共用）。
String _commentTimeText(AppLocalizations l10n, int? t) {
  if (t == null) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(t);
  final now = DateTime.now();
  final sameDay =
      dt.year == now.year && dt.month == now.month && dt.day == now.day;
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  if (sameDay) return '$hh:$mm';
  return l10n.commentTimeFormat(day: dt.day, month: dt.month, time: '$hh:$mm');
}

/// 「时间 · 属地」元信息（空项自动省略）。
String _commentMeta(AppLocalizations l10n, NeteaseComment c) {
  final location = c.location;
  return [
    _commentTimeText(l10n, c.time),
    if (location != null && location.isNotEmpty) location,
  ].where((s) => s.isNotEmpty).join(' · ');
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    this.onReply,
    this.onDelete,
    this.renderReplies = false,
  });

  final NeteaseComment comment;

  /// 回复回调；null = 隐藏回复入口（非 NK）。
  final void Function(NeteaseComment)? onReply;

  /// 删除回调；null = 隐藏删除入口（非 NK）；单个条目还须 [NeteaseComment.canDelete]。
  final void Function(NeteaseComment)? onDelete;

  /// true（仅 NK）= 展开全部楼内回复并带操作；false = 只展示第一条引用（旧样式）。
  final bool renderReplies;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final reply = comment.reply.isEmpty ? null : comment.reply.first;
    final meta = _commentMeta(l10n, comment);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(avatar: comment.avatar, name: comment.userName),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        comment.userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (comment.likedCount > 0)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            EtaIcons.thumbUpOutline,
                            size: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '${comment.likedCount}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    _TileActions(
                      l10n: l10n,
                      scheme: scheme,
                      onReply: onReply == null ? null : () => onReply!(comment),
                      onDelete: (onDelete != null && comment.canDelete)
                          ? () => onDelete!(comment)
                          : null,
                    ),
                  ],
                ),
                if (meta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      meta,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  comment.text,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
                if (renderReplies && comment.reply.isNotEmpty)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final r in comment.reply)
                        _ReplyTile(
                          reply: r,
                          onReply: onReply,
                          onDelete: onDelete,
                        ),
                    ],
                  )
                else if (reply != null)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      l10n.commentReplyFormat(text: reply.text, user: reply.userName),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 楼内回复条目（NK 展开样式；含回复 / 删除入口）。
class _ReplyTile extends StatelessWidget {
  const _ReplyTile({required this.reply, this.onReply, this.onDelete});

  final NeteaseComment reply;
  final void Function(NeteaseComment)? onReply;
  final void Function(NeteaseComment)? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final meta = _commentMeta(l10n, reply);
    final replyTo = reply.replyToName;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: reply.userName,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (replyTo != null && replyTo.isNotEmpty)
                        TextSpan(
                          text: '  ${l10n.commentReplyTo(user: replyTo)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _TileActions(
                l10n: l10n,
                scheme: scheme,
                onReply: onReply == null ? null : () => onReply!(reply),
                onDelete: (onDelete != null && reply.canDelete)
                    ? () => onDelete!(reply)
                    : null,
              ),
            ],
          ),
          if (meta.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 6),
              child: Text(
                meta,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              reply.text,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 楼层 / 回复右侧的「回复 · 删除」图标操作（回调为 null 时不渲染）。
class _TileActions extends StatelessWidget {
  const _TileActions({
    required this.l10n,
    required this.scheme,
    this.onReply,
    this.onDelete,
  });

  final AppLocalizations l10n;
  final ColorScheme scheme;
  final VoidCallback? onReply;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    if (onReply == null && onDelete == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onReply != null)
          _CommentIconAction(
            tooltip: l10n.commentReply,
            icon: EtaIcons.chatOutline,
            color: scheme.onSurfaceVariant,
            onTap: onReply!,
          ),
        if (onDelete != null)
          _CommentIconAction(
            tooltip: l10n.commonDelete,
            icon: EtaIcons.deleteOutline,
            color: scheme.onSurfaceVariant,
            onTap: onDelete!,
          ),
      ],
    );
  }
}

class _CommentIconAction extends StatelessWidget {
  const _CommentIconAction({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: color),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.avatar, required this.name});

  final String? avatar;
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = 18.0;
    final placeholder = CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      child: Text(
        name.isNotEmpty ? name.characters.first : '?',
        style: TextStyle(
          fontSize: 13,
          color: scheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    final url = avatar;
    if (url == null || url.isEmpty) return placeholder;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final avatarPx = (radius * 2 * dpr).round();
    return ClipOval(
      child: Image.network(
        withPicSize(url, 100),
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        cacheWidth: avatarPx,
        cacheHeight: avatarPx,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 40,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
