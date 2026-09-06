// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../song_list.dart';

extension _SongListActions on _SongListState {
  void _toggleSelect(Track t) {
    final key = songLikeKey(t);
    setState(() {
      if (!_selected.remove(key)) {
        _selected.add(key);
      }
    });
  }

  void _selectAll() => setState(() {
    _selected
      ..clear()
      ..addAll(widget.items.map(songLikeKey));
  });

  void _clearAll() => setState(_selected.clear);

  void _invertSelection() => setState(() {
    final inverted = {
      for (final t in widget.items)
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
