/// 通用格式化工具。
library;

/// 时钟格式（mm:ss，分秒补零，用于进度条/播放时间显示）。
String formatClock(Duration d) {
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 时长格式（m:ss / h:mm:ss，对齐原项目 formatTime；ms<=0 返回空串）。
String formatMs(int ms) {
  if (ms <= 0) return '';
  final totalSec = ms ~/ 1000;
  final h = totalSec ~/ 3600;
  final m = (totalSec % 3600) ~/ 60;
  final s = totalSec % 60;
  String pad(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${pad(m)}:${pad(s)}' : '$m:${pad(s)}';
}
