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
              Expanded(child: _buildListArea(scheme, l10n)),
              if (!_isKugou && _songId != null)
                _CommentInputBar(
                  controller: _input,
                  sending: _sending,
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
          icon: Icons.cloud_off_outlined,
          text: l10n.commentNotFound(
            _isKugou ? l10n.brandKugou : l10n.brandNetease,
          ),
        );
      }
      return const _CommentSpinner();
    }
    if (list.isEmpty) {
      return _loading
          ? const _CommentSpinner()
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
            icon: const Icon(Icons.close, size: 20),
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
    required this.sending,
    required this.theme,
    required this.scheme,
    required this.l10n,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final ThemeData theme;
  final ColorScheme scheme;
  final AppLocalizations l10n;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
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
                : const Icon(Icons.send, size: 18),
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

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment});

  final NeteaseComment comment;

  String _timeText(AppLocalizations l10n) {
    final t = comment.time;
    if (t == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(t);
    final now = DateTime.now();
    final sameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
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
