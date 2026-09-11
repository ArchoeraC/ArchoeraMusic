// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 轻量二维码渲染控件（自绘，替代已停维护的 `qr_flutter`，基于 `qr` 4）。
///
/// `qr_flutter 4.1.0` 三年未更新、写死 `qr ^3`，无法跟进 `qr` 4 的破坏性 API。
/// 本项目只需「把 URL 渲染成二维码」这一件事，故直接用 `qr` 4 的
/// [QrCode]/[QrImage] + [CustomPainter] 自绘，去掉该依赖。
library;

import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart';

/// 二维码视图。[data] 为空时渲染空白占位。
class QrImageView extends StatefulWidget {
  const QrImageView({
    super.key,
    required this.data,
    this.size = 200,
    this.color = const Color(0xFF000000),
    this.backgroundColor,
    this.errorCorrectLevel = QrErrorCorrectLevel.medium,
    this.padding = 0,
  });

  /// 待编码数据（通常为 URL）。
  final String data;

  /// 正方形边长（逻辑像素）。
  final double size;

  /// 码点颜色。
  final Color color;

  /// 背景色（null = 透明，与旧 qr_flutter 默认一致）。
  final Color? backgroundColor;

  /// 纠错等级（默认 medium，容错 ~15%，比旧默认 L 更耐污）。
  final QrErrorCorrectLevel errorCorrectLevel;

  /// 四周留白（quiet zone）。
  final double padding;

  @override
  State<QrImageView> createState() => _QrImageViewState();
}

class _QrImageViewState extends State<QrImageView> {
  QrImage? _image;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(QrImageView old) {
    super.didUpdateWidget(old);
    if (old.data != widget.data ||
        old.errorCorrectLevel != widget.errorCorrectLevel) {
      _rebuild();
    }
  }

  void _rebuild() {
    if (widget.data.isEmpty) {
      _image = null;
      return;
    }
    try {
      final code = QrCode(
        payload: QrPayload.fromString(widget.data),
        errorCorrectLevel: widget.errorCorrectLevel,
      );
      _image = QrImage(code);
    } catch (_) {
      _image = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: ColoredBox(
        color: widget.backgroundColor ?? Colors.transparent,
        child: image == null
            ? const SizedBox.expand()
            : CustomPaint(
                size: Size.square(widget.size),
                painter: _QrPainter(image, widget.color, widget.padding),
              ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image, this.color, this.padding);

  final QrImage image;
  final Color color;
  final double padding;

  @override
  void paint(Canvas canvas, Size size) {
    final n = image.moduleCount;
    final inner = size.shortestSide - padding * 2;
    if (n <= 0 || inner <= 0) return;
    final cell = inner / n;
    final paint = Paint()..color = color;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (!image.isDark(r, c)) continue;
        // +0.5 覆盖栅格化缝隙（对齐旧 gapless 行为）。
        canvas.drawRect(
          Rect.fromLTWH(
            padding + c * cell,
            padding + r * cell,
            cell + 0.5,
            cell + 0.5,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) =>
      old.image != image || old.color != color || old.padding != padding;
}
