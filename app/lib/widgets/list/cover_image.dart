// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

import '../../services/source/media_request_headers.dart';
import '../../stores/app_prefs.dart';
import '../common/anim.dart';

/// 网络封面浏览器 UA（NT 封面 CDN `p1.music.126.net` 对 Dart 默认 UA 403）。
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
/// 或加载失败时显示 [EtaIcons.music] 占位（[primaryContainer] 底）。
///
/// 像素与占位**分层**：占位常驻底层（几何稳定、立即可见），像素层
/// [CoverArt] 在解码首帧到达时淡入，见 [coverFrameFade]。
class CoverImage extends ConsumerWidget {
  const CoverImage({
    super.key,
    required this.cover,
    this.width = 48,
    this.height = 48,
    this.radius,
    this.iconSize = 22,
  });

  /// 封面地址：http(s) URL / file:// 路径 / 磁盘绝对路径。
  final String? cover;

  final double width;
  final double height;

  /// 圆角（占位与图片共用；null = 跟随「设置 → 外观 → 封面圆角」）。
  final double? radius;

  /// 占位音符图标大小。
  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final double r =
        radius ?? ref.watch(appPrefsProvider.select((p) => p.coverRadius));
    final placeholder = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(r),
      ),
      child: Icon(EtaIcons.music, size: iconSize, color: scheme.primary),
    );

    // 解码降采样：按显示尺寸 × dpr 解码，避免大图整幅解码后缩小的内存浪费
    // （封面原图常为 500~1000px，小尺寸展示时解码开销可降 90%+）。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final targetW = (width * dpr).round().clamp(1, 2048);
    final targetH = (height * dpr).round().clamp(1, 2048);

    return ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            placeholder,
            CoverArt(cover: cover, decodeWidth: targetW, decodeHeight: targetH),
          ],
        ),
      ),
    );
  }
}

/// 封面像素层（无占位、无裁剪）：铺满父级并按 [BoxFit.cover] 绘制。
///
/// 调用方负责在它**下层**放占位（[CoverImage] 与封面网格都这么做）：
/// - 解码未完成 → 本层透明，露出占位；
/// - 首帧到达 → 180ms 淡入，占位被逐帧覆盖。
///
/// [cover] 为空 / 路径不存在 / 加载失败时返回 [SizedBox.shrink]。
class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    required this.cover,
    this.decodeWidth,
    this.decodeHeight,
    this.fit = BoxFit.cover,
  });

  /// 封面地址：http(s) URL / file:// 路径 / 磁盘绝对路径。
  final String? cover;

  /// 解码降采样目标尺寸（null = 按原图解码）。
  final int? decodeWidth;
  final int? decodeHeight;

  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final provider = coverImageProvider(
      cover,
      decodeWidth: decodeWidth,
      decodeHeight: decodeHeight,
      policy: ResizeImagePolicy.fit,
    );
    if (provider == null) return const SizedBox.shrink();
    return Image(
      image: provider,
      fit: fit,
      // 失败同样回到占位层：本层留空即可，不做额外分支。
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
      frameBuilder: coverFrameFade,
    );
  }
}

/// 封面解码首帧淡入（180ms easeOut）。
///
/// 只依赖 **这张图自己的首帧**：图片由解码采样批量出帧，到达时机不受 UI
/// 控制，这里既不排队也不做错峰延迟，避免把批量解码伪装成「逐张弹出」。
/// 缓存命中（`wasSynchronouslyLoaded`）直接出图，滚动回看不重放淡入；
/// 性能模式下整层不建，直接出像素（占位仍在调用方下层，视觉一致）。
Widget coverFrameFade(
  BuildContext context,
  Widget child,
  int? frame,
  bool wasSynchronouslyLoaded,
) {
  if (wasSynchronouslyLoaded || noAnim(context)) return child;
  return AnimatedOpacity(
    opacity: frame == null ? 0 : 1,
    duration: animDuration(context, const Duration(milliseconds: 180)),
    curve: Curves.easeOut,
    child: child,
  );
}

/// 封面地址 → 按「实际需要的最大位图」在**解码阶段**降采样的 [ImageProvider]。
///
/// 封面原图常为 500~1500px，而缩略图/背景等实际展示尺寸有限；整幅解码后再缩放
/// 会白占数倍内存（RGBA 1024² ≈ 4MB）。这里统一包一层 [ResizeImage]，把 ImageCache
/// 驻留与解码开销压到真实需求上；[allowUpscaling] 关闭，小图不会被放大。
///
/// 地址解析与 [CoverImage] 一致：`//` 协议相对补 https；http(s) 走 [NetworkImage]，
/// 其余按 `file://` / 绝对路径读盘。返回 null 表示无封面或本地文件不存在。
///
/// [policy] 决定双边降采样的语义：封面类（方形裁切展示）一律传
/// [ResizeImagePolicy.fit]，否则 16:9 等非等比源会在解码层被拉变形
/// （painting 的 [BoxFit.cover] 只能在已变形的图上裁切）。
ImageProvider? coverImageProvider(
  String? cover, {
  int? decodeWidth,
  int? decodeHeight,
  ResizeImagePolicy policy = ResizeImagePolicy.exact,
}) {
  if (cover == null || cover.isEmpty) return null;
  var c = cover;
  if (c.startsWith('//')) c = 'https:$c';
  final ImageProvider base;
  if (c.startsWith('http')) {
    base = NetworkImage(c, headers: mediaHeadersForUrl(c));
  } else {
    final path = c.startsWith('file://') ? c.substring(7) : c;
    final file = File(path);
    if (!file.existsSync()) return null;
    base = FileImage(file);
  }
  if (decodeWidth == null && decodeHeight == null) return base;
  final w = (decodeWidth != null && decodeWidth > 0) ? decodeWidth : null;
  final h = (decodeHeight != null && decodeHeight > 0) ? decodeHeight : null;
  if (w == null && h == null) return base;
  return ResizeImage(
    base,
    width: w,
    height: h,
    policy: policy,
    allowUpscaling: false,
  );
}
