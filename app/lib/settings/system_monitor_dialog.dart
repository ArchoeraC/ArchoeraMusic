// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 系统监视器弹窗（Mission Center 风格）：资源卡片 + 曲线 + 会话/输入/音频状态。
///
/// 数据来源：
/// - 资源（CPU/内存/存储/运行时长/温度）：`apl_sys_stats`，1s 轮询并本地保留
///   60 点历史绘制曲线；
/// - 蓝牙：`apl_bt_state`（BlueZ）；
/// - 会话/输出：`archoera_shell_v1`（见 [osSessionProvider]）；
/// - 音频：播放器状态；输入法/光标：会话环境变量。
///
/// 与设置页解耦：设置页只留一个入口，只读状态集中在此弹窗。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../eta/icon/eta_icons.dart';
import '../l10n/l10n.dart';
import '../services/platform/os_session.dart';
import '../services/platform/platform_capabilities.dart';
import '../services/platform/system_os.dart';
import '../services/platform/system_status.dart';
import '../services/playback/playback_notifier.dart';
import '../widgets/dialogs/s_dialog.dart';

/// 打开系统监视器弹窗。
Future<void> showSystemMonitorDialog(BuildContext context) {
  return SDialog.show<void>(
    context,
    title: context.l10n.systemMonitorTitle,
    width: 760,
    child: const SystemMonitorBody(),
  );
}

/// 弹窗内容（可独立复用/测试）。
class SystemMonitorBody extends ConsumerStatefulWidget {
  const SystemMonitorBody({super.key});

  @override
  ConsumerState<SystemMonitorBody> createState() => _SystemMonitorBodyState();
}

class _SystemMonitorBodyState extends ConsumerState<SystemMonitorBody> {
  /// 曲线保留的采样点数（1s 一点 → 1 分钟）。
  static const int _historyLength = 60;

  Timer? _timer;
  SysStats? _stats;
  BluetoothState? _bt;
  final List<double> _cpuHistory = [];
  final List<double> _memHistory = [];

  @override
  void initState() {
    super.initState();
    _sample();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _sample() {
    final status = ref.read(platformCapabilitiesProvider).status;
    final stats = status.statsAvailable ? status.stats() : null;
    final bt = status.bluetoothAvailable ? status.bluetooth() : null;
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _bt = bt;
      if (stats != null) {
        if (stats.cpuPercent >= 0) {
          _push(_cpuHistory, stats.cpuPercent.toDouble());
        }
        _push(_memHistory, stats.memPercent.toDouble());
      }
    });
  }

  static void _push(List<double> samples, double value) {
    samples.add(value);
    if (samples.length > _historyLength) samples.removeAt(0);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final output = ref.watch(osOutputProvider);
    final session = ref.watch(osSessionStateProvider);
    final screenOn = ref.watch(osScreenEnabledProvider);
    final brightness = ref.watch(osBrightnessProvider);
    final battery = ref.watch(osBatteryProvider);
    final playback = ref.watch(playbackProvider);
    final stats = _stats;
    final capabilities = ref.watch(platformCapabilitiesProvider);

    final imeEnv =
        Platform.environment['GTK_IM_MODULE'] ??
        Platform.environment['QT_IM_MODULE'] ??
        Platform.environment['XMODIFIERS'] ??
        '';
    final imeLabel = imeEnv.contains('fcitx')
        ? 'fcitx5'
        : (imeEnv.contains('ibus') ? 'IBus' : l10n.systemStatusImeWayland);
    final cursorTheme =
        Platform.environment['XCURSOR_THEME'] ?? l10n.systemDisplayUnknown;
    final cursorSize = Platform.environment['XCURSOR_SIZE'] ?? '';

    final cards = <Widget>[
      _MonitorCard(
        title: l10n.systemResCpu,
        value: stats == null || stats.cpuPercent < 0
            ? '—'
            : '${stats.cpuPercent}%',
        detail: stats == null ? '' : '${stats.cpuCount} × CPU',
        chart: _cpuHistory,
        accent: isDark ? const Color(0xFF4FC3F7) : const Color(0xFF0288D1),
      ),
      _MonitorCard(
        title: l10n.systemResMemory,
        value: stats == null ? '—' : '${stats.memPercent}%',
        detail: stats == null
            ? ''
            : '${_formatKb(stats.memUsedKb)} / ${_formatKb(stats.memTotalKb)}',
        chart: _memHistory,
        accent: isDark ? const Color(0xFF9575CD) : const Color(0xFF5E35B1),
      ),
      _MonitorCard(
        title: l10n.systemResDisk,
        value: stats == null ? '—' : '${stats.diskPercent}%',
        detail: stats == null
            ? ''
            : '${_formatKb(stats.diskUsedKb)} / ${_formatKb(stats.diskTotalKb)}',
        progress: stats == null ? null : stats.diskPercent / 100,
        accent: isDark ? const Color(0xFF4DB6AC) : const Color(0xFF00796B),
      ),
      _MonitorCard(
        title: l10n.systemResTemp,
        value: stats?.tempCelsius == null
            ? '—'
            : '${stats!.tempCelsius!.toStringAsFixed(1)} °C',
        detail: stats?.tempCelsius == null ? l10n.systemDisplayUnknown : '',
        accent: isDark ? const Color(0xFFFF8A65) : const Color(0xFFE64A19),
      ),
      _MonitorCard(
        title: l10n.systemResUptime,
        value: stats?.uptimeLabel ?? '—',
        detail: '',
        accent: isDark ? const Color(0xFF90A4AE) : const Color(0xFF455A64),
      ),
      _MonitorCard(
        title: l10n.systemStatusAudio,
        value: playback.playing
            ? l10n.systemStatusPlaying
            : l10n.systemStatusIdle,
        detail: '${(playback.volume * 100).round()}%',
        progress: playback.volume.clamp(0.0, 1.0),
        accent: isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32),
      ),
      _MonitorCard(
        title: l10n.systemStatusIme,
        value: imeLabel,
        detail: '',
        accent: isDark ? const Color(0xFFFFD54F) : const Color(0xFFF9A825),
      ),
      _MonitorCard(
        title: l10n.systemStatusCursorTheme,
        value: cursorTheme,
        detail: cursorSize.isEmpty ? '' : '${cursorSize}px',
        accent: isDark ? const Color(0xFFA1887F) : const Color(0xFF5D4037),
      ),
      if (capabilities.bluetoothAvailable)
        _MonitorCard(
          title: l10n.systemBluetoothTitle,
          value: _bt == null
              ? l10n.systemBtUnavailable
              : (_bt!.present
                    ? (_bt!.adapterName ?? l10n.systemBluetoothTitle)
                    : l10n.systemBtAbsent),
          detail: _bt == null || !_bt!.present
              ? ''
              : '${_bt!.powered ? l10n.systemBtPowered : l10n.systemBtOff} · '
                    '${l10n.systemBtDevices} ${_bt!.devicesConnected}',
          accent: isDark ? const Color(0xFF64B5F6) : const Color(0xFF1565C0),
        ),
    ];

    final infoRows = <Widget>[
      _InfoRow(
        icon: EtaIcons.informationOutline,
        label: l10n.systemStatusSession,
        value: switch (session) {
          OsSessionState.ready => l10n.systemStatusReady,
          OsSessionState.suspending => l10n.systemSessionSuspending,
          OsSessionState.shuttingDown => l10n.systemSessionShuttingDown,
        },
      ),
      if (output != null)
        _InfoRow(
          icon: EtaIcons.monitorOutline,
          label: l10n.systemStatusOutput,
          value:
              '${output.width}×${output.height} · '
              '${(output.refreshMillihz / 1000).toStringAsFixed(1)} Hz · '
              '${output.scale}× · ${output.rotationDegrees}°',
        ),
      if (screenOn != null)
        _InfoRow(
          icon: EtaIcons.monitorOutline,
          label: l10n.systemScreenTitle,
          value: screenOn ? l10n.systemScreenOn : l10n.systemScreenOff,
        ),
      if (brightness != null)
        _InfoRow(
          icon: EtaIcons.brightnessOutline,
          label: l10n.systemBrightnessTitle,
          value: '$brightness%',
        ),
      if (battery != null && battery.present)
        _InfoRow(
          icon: EtaIcons.flashOutline,
          label: l10n.systemBatteryTitle,
          value:
              '${l10n.systemBatteryPercent(battery.percent)} · '
              '${battery.charging ? l10n.systemBatteryCharging : l10n.systemBatteryDischarging}',
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 560 ? 2 : 1;
            const gap = 12.0;
            final cardWidth = columns == 1
                ? constraints.maxWidth
                : (constraints.maxWidth - gap) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final card in cards)
                  SizedBox(width: cardWidth, child: card),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        Text(
          l10n.systemStatusTitle,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        ...infoRows,
      ],
    );
  }
}

/// 资源卡片：标题 + 大号数值 + 说明 + 曲线/进度条。
class _MonitorCard extends StatelessWidget {
  const _MonitorCard({
    required this.title,
    required this.value,
    required this.detail,
    required this.accent,
    this.chart,
    this.progress,
  });

  final String title;
  final String value;
  final String detail;
  final Color accent;
  final List<double>? chart;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          if (progress != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: accent.withValues(alpha: 0.18),
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            )
          else
            SizedBox(
              height: 34,
              child: CustomPaint(
                painter: _SparklinePainter(
                  samples: chart ?? const [],
                  color: accent,
                ),
                child: const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }
}

/// 只读信息行（图标 + 标签 + 值）。
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 折线 + 渐变填充（0-100 归一化）。
class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.samples, required this.color});

  final List<double> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = color.withValues(alpha: 0.16)
      ..strokeWidth = 1;
    // 三条水平参考线（25/50/75%）。
    for (final ratio in const [0.25, 0.5, 0.75]) {
      final y = size.height * (1 - ratio);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (samples.length < 2) return;

    final step = size.width / (samples.length - 1);
    final path = Path()..moveTo(0, size.height);
    for (var i = 0; i < samples.length; i++) {
      final normalized = (samples[i] / 100).clamp(0.0, 1.0);
      path.lineTo(i * step, size.height * (1 - normalized));
    }
    path
      ..lineTo(size.width, size.height)
      ..close();

    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 0.40), color.withValues(alpha: 0.02)],
      ).createShader(Offset.zero & size);
    canvas.drawPath(path, fill);

    final stroke = Path();
    for (var i = 0; i < samples.length; i++) {
      final normalized = (samples[i] / 100).clamp(0.0, 1.0);
      final point = Offset(i * step, size.height * (1 - normalized));
      if (i == 0) {
        stroke.moveTo(point.dx, point.dy);
      } else {
        stroke.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(
      stroke,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) =>
      // samples 为原地变更的滚动列表（同一引用），比较引用会漏重绘。
      true;
}

/// KiB → 人类可读（GiB / MiB）。
String _formatKb(int kb) {
  if (kb >= 1024 * 1024) return '${(kb / (1024 * 1024)).toStringAsFixed(1)} GiB';
  if (kb >= 1024) return '${(kb / 1024).toStringAsFixed(0)} MiB';
  return '$kb KiB';
}
