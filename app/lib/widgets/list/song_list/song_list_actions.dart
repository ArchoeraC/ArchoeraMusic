// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../song_list.dart';

extension _SongListActions on _SongListState {
  void _toggleSelect(Track t, int index) {
    final key = songLikeKey(t);
    setState(() {
      if (_selectAllActive) {
        // 物化全量选择为显式集合，再按行切换（保持「全库 - 取消项」语义）。
        // 保留 _allItems 作为命中项解析源（键可能不在窗口内）。
        _selected
          ..clear()
          ..addAll((_allItems ?? const <Track>[]).map(songLikeKey));
        _selectAllActive = false;
        _picked.clear();
      }
      if (_selected.remove(key)) {
        _picked.remove(key);
      } else {
        _selected.add(key);
        if (widget.totalCount != null) {
          // 窗口模式：记下 Track 本体，页淘汰后仍可解析（见 _selectedTracks）。
          _picked[key] = (track: t, index: index);
        }
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
    _picked.clear();
  });

  /// 反选。
  ///
  /// 窗口模式且全量未载入时，先经 [SongList.loadAllItems] 载入全库再反选
  /// （窗口只有部分页，无法仅凭 [SongList.items] 构造全集）。
  Future<void> _invertSelection() async {
    // 全量全选的反选 = 全部取消。
    if (_selectAllActive) {
      setState(() {
        _selectAllActive = false;
        _selected.clear();
        _picked.clear();
      });
      return;
    }
    var source = _allItems ?? widget.items;
    if (widget.totalCount != null && _allItems == null) {
      final loader = widget.loadAllItems;
      if (loader == null) return;
      final all = await loader();
      if (!mounted) return;
      setState(() => _allItems = all);
      source = all;
    }
    setState(() {
      final inverted = {
        for (final t in source)
          if (!_selected.contains(songLikeKey(t))) songLikeKey(t),
      };
      _selected
        ..clear()
        ..addAll(inverted);
      _picked.clear();
    });
  }

  void _enterBatch() => setState(() => _batchActive = true);

  void _exitBatch() => setState(() {
    _batchActive = false;
    _selected.clear();
    _picked.clear();
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
    toast(context.l10n.toastBatchAddedToQueue(count: tracks.length));
    if (mounted) _exitBatch();
  }

  Future<void> _batchDownload() async {
    final tracks = _selectedTracks;
    if (tracks.isEmpty) return;
    await downloadTracks(context, ref, tracks);
    if (mounted) _exitBatch();
  }

  /// 批量编辑元数据：委托宿主回调（本地库页接入音源注册表的编辑能力）。
  /// 宿主未提供则按钮不显示（见 [SongList.onBatchEditMetadata]）。
  Future<void> _batchEditMetadata() async {
    final handler = widget.onBatchEditMetadata;
    if (handler == null) return;
    final tracks = _selectedTracks;
    if (tracks.isEmpty) return;
    await handler(tracks);
    if (mounted) _exitBatch();
  }
}
