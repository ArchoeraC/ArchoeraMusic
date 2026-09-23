part of '../easter_egg.dart';

// ── 媒体类彩蛋 ────────────────────────────────────────────────────────

/// #9 立刻暂停音乐，并「只要开始播放就立刻暂停」——永久生效（重启前一直锁定）。
Future<void> _pauseLock(EasterEggContext ctx) async {
  final ref = ctx.ref;
  if (ref == null) return;
  final notifier = ref.read(playbackProvider.notifier);
  notifier.pause();
  final container = ProviderScope.containerOf(ctx.context, listen: false);
  container.listen<PlaybackState>(playbackProvider, (_, next) {
    if (next.playing) notifier.pause();
  });
}
