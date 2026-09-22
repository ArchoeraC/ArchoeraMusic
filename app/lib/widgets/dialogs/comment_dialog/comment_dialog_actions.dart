// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../comment_dialog.dart';

extension _CommentDialogActions on _CommentDialogState {
  /// 解析评论目标 id（各源差异全在 [CommentPlatform.resolveTarget]；可能弹登录）。
  Future<void> _match() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final id = await _platform.resolveTarget(context, ref, widget.track);
      if (!mounted) return;
      if (id == null || id.isEmpty) {
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

  Future<void> _load({bool reset = false}) async {
    final id = _songId;
    if (id == null) return;
    if (!reset &&
        (_page?.list.length ?? 0) >= _CommentDialogState._maxComments) {
      return;
    }
    final nextPage = reset ? 1 : (_page?.page ?? 1) + 1;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await _platform.fetchPage(
        ref,
        id,
        hot: _hot,
        page: nextPage,
      );
      if (!mounted) return;
      setState(() {
        _page = reset ? page : _mergePage(page, nextPage);
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

  NeteaseCommentPage _mergePage(NeteaseCommentPage next, int page) {
    final merged = [...?_page?.list, ...next.list];
    final capped = merged.length > _CommentDialogState._maxComments
        ? merged.sublist(merged.length - _CommentDialogState._maxComments)
        : merged;
    return NeteaseCommentPage(
      list: capped,
      total: next.total,
      page: page,
      limit: next.limit,
    );
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240) {
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

  Future<void> _send() async {
    final id = _songId;
    if (id == null || !_canSend || _sending) return;
    final content = _input.text.trim();
    final l10n = context.l10n;
    if (content.isEmpty) {
      toast(l10n.commentInputEmpty);
      return;
    }
    setState(() => _sending = true);
    try {
      final ok = await _platform.send(
        context,
        ref,
        id,
        content,
        parentId: _replyTo?.id,
      );
      if (!mounted || !ok) return;
      _input.clear();
      setState(() => _replyTo = null);
      toast(l10n.commentPublished, type: ToastType.success);
      // 热门 Tab 下新评论会出现在「最新」：切过去展示；否则直接重载。
      if (_platform.supportsHot && _hot) {
        _switchTab(false);
      } else {
        await _load(reset: true);
      }
    } catch (e) {
      if (!mounted) return;
      toast(
        e is CommentOperationException
            ? e.message
            : l10n.commentSendFailed(msg: '$e'),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 点「回复」：记住目标并聚焦输入框（仅 [CommentPlatform.supportsReply]）。
  void _startReply(NeteaseComment target) {
    setState(() => _replyTo = target);
    _inputFocus.requestFocus();
  }

  void _cancelReply() {
    if (_replyTo == null) return;
    setState(() => _replyTo = null);
  }

  /// 删除评论（仅 [CommentPlatform.supportsDelete]；服务端自行鉴权）。
  Future<void> _deleteComment(NeteaseComment target) async {
    if (!_platform.supportsDelete) return;
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.commonDelete),
        content: Text(l10n.commentDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _platform.delete(ref, target.id);
      if (!mounted) return;
      if (_replyTo?.id == target.id) setState(() => _replyTo = null);
      toast(l10n.commentDeleted, type: ToastType.success);
      await _load(reset: true);
    } catch (e) {
      if (!mounted) return;
      toast(l10n.commentDeleteFailed(msg: '$e'));
    }
  }
}
