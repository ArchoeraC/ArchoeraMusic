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
        _applyTask(
          taskId,
          (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
            status: to,
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
      case 'already':
        _applyTask(
          taskId,
          (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
            status: 'already',
            filePath: evt['filePath'] as String?,
          ),
        );
    }
    _pruneHistory();
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
