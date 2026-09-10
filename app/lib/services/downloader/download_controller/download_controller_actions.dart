// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../download_controller.dart';

mixin _DownloadControllerActions
    on
        Notifier<DownloadState>,
        _DownloadControllerCore,
        _DownloadControllerEvents {
  String? _enqueue(Track track, {String? quality}) {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return null;
    final q = quality ?? ref.read(appPrefsProvider).downloadQuality;
    final (code, taskId) = engine.enqueue(
      buildDownloadRequest(track, quality: q),
    );
    if (code != 0 || taskId.isEmpty) return null;
    _applyTask(
      taskId,
      (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
        trackId: track.id,
        source: track.source,
        platformId: track.id,
        title: track.title,
        artist: track.artistNames,
        album: track.album?.name ?? '',
        quality: q,
      ),
    );
    return taskId;
  }

  void _cancel(String taskId) {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    engine.cancel(taskId);
    _applyTask(
      taskId,
      (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
        status: 'canceled',
        error: '已取消',
        retryable: false,
      ),
    );
  }

  void _retry(String taskId) {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    engine.retry(taskId);
  }

  void _pause(String taskId) {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    engine.pause(taskId);
    _applyTask(
      taskId,
      (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
        status: 'paused',
        speed: 0,
      ),
    );
  }

  void _removeTask(String taskId, {bool deleteFile = false}) {
    _removedIds.add(taskId);
    final engine = _engine;
    if (engine != null && engine.isInitialized) {
      engine.remove(taskId, deleteFile: deleteFile);
    }
    state = state.copyWith(
      tasks: state.tasks.where((t) => t.taskId != taskId).toList(),
    );
  }

  void _clearTasks({bool deleteFiles = false}) {
    final engine = _engine;
    if (engine != null && engine.isInitialized) {
      engine.clear(deleteFiles: deleteFiles);
    }
    _removedIds.addAll(state.tasks.map((t) => t.taskId));
    state = state.copyWith(tasks: const []);
  }

  void _pauseAll() {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    engine.pauseAll();
    final tasks = state.tasks
        .map((t) => t.isActive ? t.copyWith(status: 'paused', speed: 0) : t)
        .toList();
    state = state.copyWith(tasks: tasks);
  }

  void _resumeAll() {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    engine.resumeAll();
  }

  void _removeTasks(Iterable<String> taskIds, {bool deleteFile = false}) {
    final ids = taskIds.toSet();
    if (ids.isEmpty) return;
    _removedIds.addAll(ids);
    final engine = _engine;
    if (engine != null && engine.isInitialized) {
      for (final id in ids) {
        engine.remove(id, deleteFile: deleteFile);
      }
    }
    state = state.copyWith(
      tasks: state.tasks.where((t) => !ids.contains(t.taskId)).toList(),
    );
  }

  @override
  void _setMaxSpeed(int bytesPerSec) {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    engine.setMaxSpeed(bytesPerSec);
  }
}
