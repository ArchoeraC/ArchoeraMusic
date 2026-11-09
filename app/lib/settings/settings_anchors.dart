// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

/// 设置项锚点登记表（搜索跳转定位用）。
///
/// 以「当前语言的标题文本」为键登记 [BuildContext]：设置内容同一时刻只构建
/// 一个分类、且同一分类内标题唯一，因此按文本即可定位到对应设置行或小节
/// 标题。用 StatefulWidget 登记/注销而不是 GlobalKey——重复标题只会让后者
/// 覆盖前者，不会抛 duplicate-key。
class SettingsAnchors {
  final Map<String, BuildContext> _contexts = {};

  void register(String label, BuildContext context) =>
      _contexts[label] = context;

  void unregister(String label, BuildContext context) {
    if (identical(_contexts[label], context)) _contexts.remove(label);
  }

  BuildContext? lookup(String label) => _contexts[label];
}

/// 全局锚点表（设置弹窗独占：同一时刻只会存在一个设置弹窗实例）。
final settingsAnchors = SettingsAnchors();

/// 把 [child] 登记为 [label] 对应的滚动/高亮目标。
///
/// 包在设置行（[SettingTile]）与小节标题（[SettingSectionTitle]）外层；
/// 搜索命中后由设置弹窗取出 `BuildContext` 做 `Scrollable.ensureVisible`。
class SettingsAnchor extends StatefulWidget {
  const SettingsAnchor({super.key, required this.label, required this.child});

  /// 锚点键（标题文本，与搜索索引里的标题一致）。
  final String label;

  final Widget child;

  @override
  State<SettingsAnchor> createState() => _SettingsAnchorState();
}

class _SettingsAnchorState extends State<SettingsAnchor> {
  @override
  void initState() {
    super.initState();
    settingsAnchors.register(widget.label, context);
  }

  @override
  void didUpdateWidget(SettingsAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.label != widget.label) {
      settingsAnchors.unregister(oldWidget.label, context);
      settingsAnchors.register(widget.label, context);
    }
  }

  @override
  void dispose() {
    settingsAnchors.unregister(widget.label, context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
