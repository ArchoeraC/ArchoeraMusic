// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../song_list.dart';

extension _SongListActions on _SongListState {
  void _toggleSelect(Track t) {
    final key = songLikeKey(t);
    setState(() {
      if (_selectAllActive) {
        // 物化全量选择为显式集合，再按行切换（保持「全库 - 取消项」语义）。
        // 保留 _allItems 作为命中项解析源（键可能不在窗口内）。
        _selected
          ..clear()
          ..addAll((_allItems ?? const <Track>[]).map(songLikeKey));
        _selectAllActive = false;
      }
      if (!_selected.remove(key)) {
        _selected.add(key);
      }
    });
  }

  /// 全选：有 [SongList.loadAllItems] 时载入全量（整库/整个搜索结果），
  /// 否则仅选择当前窗口。
  Future<void> _selectAll() async {
    final loader = widget.loadAllItems;
    if (loader == null) {
      setState(() {
        _selected
          ..clear()
          ..addAll(widget.items.map(songLikeKey));
      });
      return;
    }
    if (!mounted) return;
    setState(() => _selectAllActive = true);
    try {
      final all = await loader();
      if (!mounted) return;
      setState(() => _allItems = all);
    } catch (_) {
      if (mounted) setState(() => _selectAllActive = false);
    }
  }

  void _clearAll() => setState(() {
    _selectAllActive = false;
    _allItems = null;
    _selected.clear();
  });

  void _invertSelection() => setState(() {
    // 全量全选的反选 = 全部取消。
    if (_selectAllActive) {
      _selectAllActive = false;
      _selected.clear();
      return;
    }
    final source = _allItems ?? widget.items;
    final inverted = {
      for (final t in source)
        if (!_selected.contains(songLikeKey(t))) songLikeKey(t),
    };
    _selected
      ..clear()
      ..addAll(inverted);
  });

  void _enterBatch() => setState(() => _batchActive = true);

  void _exitBatch() => setState(() {
    _batchActive = false;
    _selected.clear();
    _selectAllActive = false;
    _allItems = null;
  });

  Future<void> _batchPlay() async {
    final tracks = _selectedTracks;
    if (tracks.isEmpty) return;
    await ref.read(playbackProvider.notifier).playQueue(tracks);
    if (mounted) _exitBatch();
  }

  void _batchAddQueue() {
    final tracks = _selectedTracks;
    if (tracks.isEmpty) return;
    final notifier = ref.read(playbackProvider.notifier);
    for (final t in tracks) {
      notifier.insertToQueue(t);
    }
    toast(context.l10n.toastBatchAddedToQueue(tracks.length));
    if (mounted) _exitBatch();
  }

  Future<void> _batchDownload() async {
    final tracks = _selectedTracks;
    if (tracks.isEmpty) return;
    await downloadTracks(context, ref, tracks);
    if (mounted) _exitBatch();
  }
}
