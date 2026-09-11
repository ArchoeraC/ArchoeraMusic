// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全局 toast 消息提示（classic 卡片风格：主题背景 + 类型彩色边框）。
///
/// 布局：顶部居中堆叠；内容行 = 类型图标 + 文字（Flexible 限宽，超长
/// 自动换行）。文字用主题 bodySmall（自带字体回退链、onSurface 前景与
/// 均匀行内分布——ToastOverlay 位于 Material 之外，裸 TextStyle 会丢失
/// 字体导致显示异常）。进入/离开动画 = 淡入 + 下滑。无关闭按钮、不拦截
/// 点击（纯展示，pointer-events-none）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'toast/toast_overlay.dart';

/// toast 类型（对齐原项目 ToastType；default/info 同色系）。
enum ToastType { default_, info, success, warning, error }

/// 单条 toast 数据。
class ToastItem {
  ToastItem({
    required this.id,
    required this.type,
    required this.message,
    required this.duration,
  });

  final int id;
  final ToastType type;
  final String message;
  final Duration duration;

  /// 是否处于离开动画（真实移除前短暂保留，供退场过渡）。
  bool leaving = false;
}

/// 全局 toast 控制器：队列 + 自动关闭定时；ToastOverlay 监听渲染。
class ToastController extends ChangeNotifier {
  static const int maxToasts = 5;

  final List<ToastItem> _items = [];
  int _nextId = 0;

  List<ToastItem> get items => List.unmodifiable(_items);

  /// 弹出 toast。满队列时移除最早一条（对齐原版 while length >= max）。
  void show(
    String message, {
    ToastType type = ToastType.default_,
    Duration duration = const Duration(milliseconds: 3000),
  }) {
    while (_items.length >= maxToasts) {
      _items.removeAt(0);
    }
    final item = ToastItem(
      id: _nextId++,
      type: type,
      message: message,
      duration: duration,
    );
    _items.add(item);
    notifyListeners();
    // 自动关闭（与进度条动画时长一致）
    Timer(item.duration, () => dismiss(item.id));
  }

  /// 标记离开动画；动画结束后由 [remove] 真正移除。
  void dismiss(int id) {
    final idx = _items.indexWhere((t) => t.id == id);
    if (idx == -1 || _items[idx].leaving) return;
    _items[idx].leaving = true;
    notifyListeners();
  }

  void remove(int id) {
    final before = _items.length;
    _items.removeWhere((t) => t.id == id);
    if (_items.length != before) notifyListeners();
  }
}

/// 全局单例（应用内唯一，ToastOverlay 注册监听）。
final ToastController toastController = ToastController();

/// 便捷 API：`toast('已复制', type: ToastType.success)`。
void toast(
  String message, {
  ToastType type = ToastType.default_,
  Duration duration = const Duration(milliseconds: 3000),
}) {
  toastController.show(message, type: type, duration: duration);
}

/// 覆盖层宿主：挂在 MaterialApp.builder 最外层，叠在 Navigator 之上，
/// 顶部居中渲染 toast 队列（不拦截下层点击）。
class ToastOverlay extends StatelessWidget {
  const ToastOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _buildToastOverlay(context);
}
