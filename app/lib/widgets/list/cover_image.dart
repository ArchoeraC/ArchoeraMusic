import 'dart:io';

import 'package:flutter/material.dart';

/// 网络封面浏览器 UA（网易云封面 CDN `p1.music.126.net` 对 Dart 默认 UA 403）。
///
/// 通过 [HttpOverrides] 设为全局 HttpClient 默认 UA：Flutter [Image.network]
/// 内部用 `request.headers.add` 追加自定义头，若经 headers 传 UA 会与默认
/// `Dart/x (dart:io)` 叠加成双 UA 头，CDN 拒收；改默认 UA 则天然单头。
const coverUserAgent =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// 封面图（网络图 / `file://` 本地文件 / 磁盘路径；失败回退音符占位）。
///
/// 供歌曲列表、播放栏、全屏播放器等处复用：[cover] 为空、路径不可解析
/// 或加载失败时显示 [Icons.music_note] 占位（[primaryContainer] 底）。
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.cover,
    this.width = 48,
    this.height = 48,
    this.radius = 8,
    this.iconSize = 22,
  });

  /// 封面地址：http(s) URL / file:// 路径 / 磁盘绝对路径。
  final String? cover;

  final double width;
  final double height;

  /// 圆角（占位与图片共用）。
  final double radius;

  /// 占位音符图标大小。
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(Icons.music_note, size: iconSize, color: scheme.primary),
    );

    final c = cover;
    if (c == null || c.isEmpty) return placeholder;

    final Widget image;
    if (!c.startsWith('http')) {
      // 本地文件：file:// 前缀剥离后按绝对路径读
      final filePath = c.startsWith('file://') ? c.substring(7) : c;
      final file = File(filePath);
      if (!file.existsSync()) return placeholder;
      image = Image.file(
        file,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      );
    } else {
      image = Image.network(
        c,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: image,
    );
  }
}
