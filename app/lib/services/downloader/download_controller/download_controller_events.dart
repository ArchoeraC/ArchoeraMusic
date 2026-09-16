// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../download_controller.dart';

mixin _DownloadControllerEvents
    on Notifier<DownloadState>, _DownloadControllerCore {
  @override
  void _handleEvent(Map<String, dynamic> evt) {
    final taskId = evt['taskId'] as String?;
    if (taskId == null || taskId.isEmpty) return;
    if (_removedIds.contains(taskId)) return;
    switch (evt['type'] as String?) {
      case 'state':
        final to = evt['to'] as String? ?? 'queued';
        final from = evt['from'] as String? ?? '';
        // 失败/取消后重试进入新一轮（queued/resolving）：清空上一轮进度残留，
        // 避免旧确定进度条在解析阶段残留。暂停→恢复（from='paused'）保留已收字节。
        final restarted =
            (to == 'queued' || to == 'resolving') &&
            (from == 'failed' || from == 'canceled');
        _applyTask(
          taskId,
          (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
            status: to,
            resetProgress: restarted,
            speed:
                (to == 'paused' ||
                    to == 'done' ||
                    to == 'canceled' ||
                    to == 'failed')
                ? 0
                : null,
          ),
        );
      case 'progress':
        _applyTask(
          taskId,
          (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
            received: (evt['received'] as num?)?.toInt() ?? 0,
            total: (evt['total'] as num?)?.toInt(),
            speed: (evt['speed'] as num?)?.toInt(),
          ),
        );
      case 'done':
        _applyTask(taskId, (t) {
          final cur = t ?? DownloadTask(taskId: taskId);
          final enrTitle = evt['title'] as String? ?? '';
          final enrArtist = evt['artist'] as String? ?? '';
          final enrAlbum = evt['album'] as String? ?? '';
          return cur.copyWith(
            status: 'done',
            filePath: evt['filePath'] as String?,
            fileSize: (evt['fileSize'] as num?)?.toInt(),
            actualQuality: evt['actualQuality'] as String?,
            title: enrTitle.isNotEmpty ? enrTitle : null,
            artist: enrArtist.isNotEmpty ? enrArtist : null,
            album: enrAlbum.isNotEmpty ? enrAlbum : null,
          );
        });
        _forgetTracks([taskId]);
      case 'error':
        final msg = evt['error'] as String? ?? '未知错误';
        final canceled = msg == '已取消';
        _applyTask(
          taskId,
          (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
            status: canceled ? 'canceled' : 'failed',
            error: msg,
            retryable: evt['retryable'] as bool? ?? false,
            stage: evt['stage'] as String?,
          ),
        );
        // §12.1 解析失败 → 复用播放管线解析 URL 后回退下载（仅 kugou/netease）。
        if (!canceled &&
            evt['stage'] == 'resolving' &&
            (evt['retryable'] as bool? ?? false)) {
          _scheduleFallback(taskId);
        }
      case 'already':
        _applyTask(
          taskId,
          (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
            status: 'already',
            filePath: evt['filePath'] as String?,
          ),
        );
        _forgetTracks([taskId]);
    }
    _pruneHistory();
    // 任务态变化后重估空闲释放（页面不可见且无在途任务时延时销毁引擎）。
    _scheduleIdleSuspend();
  }

  void _applyTask(String taskId, DownloadTask Function(DownloadTask?) update) {
    final tasks = List<DownloadTask>.of(state.tasks);
    final idx = tasks.indexWhere((t) => t.taskId == taskId);
    final next = update(idx >= 0 ? tasks[idx] : null);
    if (idx >= 0) {
      tasks[idx] = next;
    } else {
      tasks.add(next);
    }
    state = state.copyWith(tasks: tasks);
  }

  @override
  void _pruneHistory() {
    final limit = ref.read(downloadHistoryLimitProvider);
    final tasks = state.tasks;
    final finished = tasks.where((t) => t.isDone || t.isFailed).length;
    if (finished <= limit) return;
    final dropCount = finished - limit;
    final dropIds = <String>{};
    for (final t in tasks) {
      if (dropIds.length >= dropCount) break;
      if (t.isDone || t.isFailed) dropIds.add(t.taskId);
    }
    if (dropIds.isEmpty) return;
    state = state.copyWith(
      tasks: tasks.where((t) => !dropIds.contains(t.taskId)).toList(),
    );
  }
}
