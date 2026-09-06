// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../comment_dialog.dart';

extension _CommentDialogActions on _CommentDialogState {
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
      final page = _isKugou
          ? await _loadKg(id, page: nextPage)
          : _hot
          ? await _api.songHotComments(id, page: nextPage)
          : await _api.songComments(id, page: nextPage);
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

  Future<NeteaseCommentPage> _loadKg(String hash, {required int page}) async {
    final kp = await ref.read(kugouApiProvider).songComments(hash, page: page);
    return NeteaseCommentPage(
      list: kp.list.map(_kgToTile).toList(),
      total: kp.total,
      page: kp.page,
      limit: kp.limit,
    );
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
}
