// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../fps_monitor.dart';

extension _FpsOverlayView on _FpsOverlayState {
  Color _fpsColor() {
    if (_idle) return const Color(0xFF90A4AE);
    if (_fps >= 55) return const Color(0xFF4CAF50);
    if (_fps >= 30) return const Color(0xFFFFC107);
    return const Color(0xFFF44336);
  }

  /// 帧耗时分组明细（p50/p95，单位 ms）。
  ///
  /// 三段分开归属：UI 贵 → 缓存/批处理问题；R（raster）贵 → 填充率/离屏层问题；
  /// 队列贵 → 帧调度/线程切换延迟。统计窗口含本浮层自身每秒一次的 setState 帧，
  /// 对分位数是可忽略的稀释项。
  String _detailLine() {
    final ui = _stats.statsFor(FrameDurationFamily.build);
    final raster = _stats.statsFor(FrameDurationFamily.raster);
    final queue = _stats.statsFor(FrameDurationFamily.rasterQueue);
    if (ui == null || raster == null) return 'UI/R 无样本';
    String ms(int? us) => ((us ?? 0) / 1000).toStringAsFixed(1);
    final tier = widget.tier;
    final tierLabel = switch (tier) {
      null => '',
      RenderQualityTier.full => ' · 满',
      RenderQualityTier.balanced => ' · 中',
      RenderQualityTier.performance => ' · 降',
    };
    return 'UI ${ms(ui.p50Us)}/${ms(ui.p95Us)} · '
        'R ${ms(raster.p50Us)}/${ms(raster.p95Us)} · '
        '队列 ${ms(queue?.p95Us)}$tierLabel ms（p50/p95）';
  }

  Widget _buildFpsOverlay(BuildContext context) {
    final color = _fpsColor();
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _toggleVisible,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: _visible
              ? Text(
                  _idle
                      ? 'idle · ${_rssMb}MB'
                      : 'FPS ${_fps.toStringAsFixed(0)} · '
                            '${_frameMs.toStringAsFixed(1)}ms · ${_rssMb}MB\n'
                            '${_detailLine()}',
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                )
              : Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
        ),
      ),
    );
  }
}
