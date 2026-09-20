// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

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

/// 按显示模式返回「播放时间对」（左 / 右），对齐上游 player.timeFormat：
/// - `current-total`：左=已播，右=总时长；
/// - `remaining-total`：左=剩余（带 `-`），右=总时长；
/// - `current-remaining`：左=已播，右=剩余（带 `-`）。
///
/// 位置超出总时长时剩余按 0 计。
(String, String) formatTimePair(Duration pos, Duration dur, String mode) {
  final current = formatClock(pos);
  final total = formatClock(dur);
  final remain = formatClock(dur > pos ? dur - pos : Duration.zero);
  return switch (mode) {
    'remaining-total' => ('-$remain', total),
    'current-remaining' => (current, '-$remain'),
    _ => (current, total),
  };
}

/// 单串形式（播放条用）：`左 / 右`，格式见 [formatTimePair]。
String formatTimeLabel(Duration pos, Duration dur, String mode) {
  final (left, right) = formatTimePair(pos, dur, mode);
  return '$left / $right';
}

/// 字节数人类可读（B / KB / MB / GB / TB；<=0 返回 "0 B"）。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}
