/// 歌曲评论弹窗（网易云对齐原项目 Comments.vue 核心交互；酷狗走
/// mcomment commentsv2/getCommentWithLike）。
///
/// 入口 [showCommentDialog]：网易云源先 [NeteaseApi.findNeteaseCommentId]
/// 匹配网易云歌曲 id（异源走云搜索），再分「热门 / 最新」两 Tab 分页拉取；
/// 酷狗源直接用歌曲 hash 拉酷狗评论（无 Tab）。触底自动加载下一页。
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

/// 酷狗评论 → 弹窗通用展示模型（字段与 NeteaseComment 对齐）。
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
Future<void> showCommentDialog(
  BuildContext context, {
  required Track track,
}) {
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
  /// 匹配到的网易云歌曲 id（null = 匹配中/失败）。
  String? _songId;

  /// 当前 Tab：true = 热门。
  bool _hot = true;

  NeteaseCommentPage? _page;
  bool _loading = true;
  bool _failed = false;
  final ScrollController _scroll = ScrollController();

  /// 发送评论输入框（仅网易云源显示；酷狗发送接口需签名鉴权，未接入）。
  final TextEditingController _input = TextEditingController();
  bool _sending = false;

  NeteaseApi get _api => ref.read(neteaseApiProvider);

  /// 是否酷狗源（直接按歌曲 hash 拉酷狗评论，无 Tab、无需登录）。
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

  /// 匹配歌曲 id → 拉首屏（酷狗源直接用歌曲 hash）。
  Future<void> _match() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      if (_isKugou) {
        final hash = widget.track.kugou?.hash;
        if (hash == null || hash.isEmpty) {
          setState(() {
            _loading = false;
            _failed = true;
          });
          return;
        }
        if (!mounted) return;
        setState(() => _songId = hash);
        await _load(reset: true);
        return;
      }
      final id = await _api.findNeteaseCommentId(widget.track);
      if (!mounted) return;
      if (id == null) {
        setState(() {
          _loading = false;
          _failed = true;
        });
        return;
      }
      setState(() => _songId = id);
      await _load(reset: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// 拉取当前 Tab 的一页（[reset] 清空列表从头加载）。
  Future<void> _load({bool reset = false}) async {
    final id = _songId;
    if (id == null) return;
    final nextPage = reset ? 1 : (_page?.page ?? 1) + 1;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = _isKugou
          ? await _loadKg(id, page: nextPage)
          : _hot
              ? await _api.songHotComments(id, page: nextPage)
              : await _api.songComments(id, page: nextPage);
      if (!mounted) return;
      setState(() {
        _page = reset
            ? page
            : NeteaseCommentPage(
                list: [...?_page?.list, ...page.list],
                total: page.total,
                page: nextPage,
                limit: page.limit,
              );
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// 酷狗源拉取一页（按 hash 请求，KugouComment 转展示模型）。
  Future<NeteaseCommentPage> _loadKg(String hash, {required int page}) async {
    final kp = await ref.read(kugouApiProvider).songComments(hash, page: page);
    return NeteaseCommentPage(
      list: kp.list.map(_kgToTile).toList(),
      total: kp.total,
      page: kp.page,
      limit: kp.limit,
    );
  }

  void _onScroll() {
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 240) {
      _load();
    }
  }

  void _switchTab(bool hot) {
    if (hot == _hot) return;
    setState(() {
      _hot = hot;
      _page = null;
    });
    _load(reset: true);
  }

  /// 发表评论（仅网易云源可用）：
  /// 未登录先引导扫码登录；空内容 / 重复评论（code 505）等失败均 toast。
  Future<void> _send() async {
    final id = _songId;
    if (id == null || _isKugou || _sending) return;
    final content = _input.text.trim();
    final l10n = context.l10n;
    if (content.isEmpty) {
      toast(l10n.commentInputEmpty);
      return;
    }
    final account = ref.read(neteaseAuthProvider);
    if (account == null) {
      toast(l10n.commentLoginRequired(l10n.brandNetease));
      showNeteaseLoginDialog(context);
      return;
    }
    setState(() => _sending = true);
    try {
      await _api.sendComment(id, content);
      if (!mounted) return;
      _input.clear();
      toast(l10n.commentPublished, type: ToastType.success);
      // 切到「最新」Tab 刷新，新评论会排在最前；已在最新 Tab 则直接刷新
      if (_hot) {
        _switchTab(false);
      } else {
        await _load(reset: true);
      }
    } catch (e) {
      if (!mounted) return;
      final err = e is NeteaseApiError ? e : null;
      final code = err?.body?['code'];
      toast(code == 505 ? l10n.commentDuplicate : l10n.commentSendFailed('$e'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      // 裁剪整个弹窗画布到 shape 圆角（Dialog 默认 Clip.none）
      clipBehavior: Clip.antiAlias,
      // 图片风格下为毛玻璃（blur(16)），背景图不再清晰透出
      child: GlassDialogSurface(
        radius: BorderRadius.circular(16),
        color: scheme.surfaceContainer,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 560,
            maxHeight: 560,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            // ── 标题行 ─────────────────────────────────────────
            Padding(
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
                          widget.track.title,
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
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // ── Tab：热门 / 最新（酷狗无「最新」，整行隐藏）──────────
            if (!_isKugou)
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
            // ── 评论列表 ───────────────────────────────────────
            Expanded(child: _buildListArea(scheme, l10n)),
            // ── 发送评论输入栏（仅网易云源；酷狗接口需签名鉴权未接入）────
            if (!_isKugou && _songId != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        enabled: !_sending,
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
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: l10n.commentSend,
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send, size: 18),
                    ),
                  ],
                ),
              ),
          ],
        ),
        ),
      ),
    );
  }

  /// 评论列表区：未取到 songId → 失败/加载中；空列表 → 加载中/空提示；
  /// 否则分页列表（触底追加 loading 行 / 无更多提示）。
  Widget _buildListArea(ColorScheme scheme, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final page = _page;
    final list = page?.list ?? const <NeteaseComment>[];
    final hasMore = _songId != null && page != null && page.hasMore;
    if (_songId == null) {
      if (_failed) {
        return _EmptyHint(
          icon: Icons.cloud_off_outlined,
          text: l10n.commentNotFound(
              _isKugou ? l10n.brandKugou : l10n.brandNetease),
        );
      }
      return _commentSpinner();
    }
    if (list.isEmpty) {
      return _loading
          ? _commentSpinner()
          : _EmptyHint(icon: Icons.forum_outlined, text: l10n.commentEmpty);
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
        return _CommentTile(comment: list[index]);
      },
    );
  }

  Widget _commentSpinner() {
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    );
  }
}

/// 单条评论。
class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment});

  final NeteaseComment comment;

  String _timeText(AppLocalizations l10n) {
    final t = comment.time;
    if (t == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(t);
    final now = DateTime.now();
    final sameDay = dt.year == now.year &&
        dt.month == now.month &&
        dt.day == now.day;
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    if (sameDay) return '$hh:$mm';
    return l10n.commentTimeFormat(dt.day, dt.month, '$hh:$mm');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    // 被引用的回复（仅显示首条）
    final reply = comment.reply.isEmpty ? null : comment.reply.first;
    final meta = [
      _timeText(l10n),
      if (comment.location != null && comment.location!.isNotEmpty)
        comment.location!,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像
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
                            Icons.thumb_up_alt_outlined,
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
                // 被引用的回复（仅显示首条）
                if (reply != null)
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
                      l10n.commentReplyFormat(reply.text, reply.userName),
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

/// 用户头像（网络图 / 昵称首字占位）。
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
    return ClipOval(
      child: Image.network(
        withPicSize(url, 100),
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}

/// 空态 / 失败提示。
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
          Icon(icon, size: 40, color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 10),
          Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
