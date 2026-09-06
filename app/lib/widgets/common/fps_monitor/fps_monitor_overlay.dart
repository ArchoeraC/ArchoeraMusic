// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../fps_monitor.dart';

extension _FpsOverlayView on _FpsOverlayState {
  Color _fpsColor() {
    if (_fps >= 55) return const Color(0xFF4CAF50);
    if (_fps >= 30) return const Color(0xFFFFC107);
    return const Color(0xFFF44336);
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
                  'FPS ${_fps.toStringAsFixed(0)} · '
                  '${_frameMs.toStringAsFixed(1)}ms · ${_rssMb}MB',
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
