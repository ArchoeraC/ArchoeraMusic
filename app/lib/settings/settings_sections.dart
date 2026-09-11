// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 设置弹窗各分类内容组件（从 settings_dialog.dart 拆出，独立类组件）。
///
/// 每个分类一个 `ConsumerStatefulWidget`，自行持有分类专属的控制器 /
/// 草稿值 / 私有辅助方法，仅在 build 内从 ref 读取偏好与 l10n。
library;

import 'dart:async' show StreamSubscription;
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io' show File, Platform, Process, ProcessStartMode;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../app/app_quit.dart';
import '../app/theme_provider.dart';
import '../app/watermark.dart';
import '../services/downloader/download_controller.dart';
import '../services/playback/engine_bindings.dart';
import '../services/playback/playback_notifier.dart';
import '../services/scraper/scrape_controller.dart';
import '../services/shortcuts/shortcut_action.dart';
import '../services/shortcuts/shortcut_binding.dart';
import '../stores/app_prefs.dart';
import '../stores/data_dir.dart';
import '../theme/app_theme.dart';
import '../widgets/common/toast.dart';
import '../widgets/dialogs/s_dialog.dart';
import '../widgets/player/s_controls.dart';
import 'settings_color_picker.dart';
import 'settings_widgets.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'settings_sections/settings_sections_appearance.dart';
part 'settings_sections/settings_sections_playback.dart';
part 'settings_sections/settings_sections_shortcuts.dart';
part 'settings_sections/settings_sections_lyrics.dart';
part 'settings_sections/settings_sections_preset.dart';
part 'settings_sections/settings_sections_download.dart';
part 'settings_sections/settings_sections_scrape.dart';
part 'settings_sections/settings_sections_storage.dart';
part 'settings_sections/settings_sections_about.dart';
part 'settings_sections/settings_sections_developer.dart';

// ── 输出设备（引擎 list_sinks JSON → Dart 模型）──────────────────────

/// 引擎枚举的单个音频输出设备（`archoera_mediaengine_list_sinks` 结果）。
class _SinkDevice {
  const _SinkDevice({
    required this.id,
    required this.name,
    required this.rate,
    required this.channels,
    required this.isDefault,
    required this.cls,
  });

  final String id;
  final String name;

  /// 设备原生采样率（Hz）。
  final int rate;

  /// 设备原生声道数。
  final int channels;

  /// 是否为系统当前默认输出（引擎标记）。
  final bool isDefault;

  /// 引擎上报的设备类别（JSON `class`：a2dp|hfp|low|hdmi|usb|internal|unknown）。
  /// 运行时缺字段/未知值一律解析为 `'unknown'`（按非通话类兼容处理）。
  final String cls;

  /// 是否通话/低质类（HFP 免提、通话音档、单声道/低采样等）——音乐经其输出
  /// 接近“毁音质”，部分耳机甚至故意不兼容可能无声/异常。
  ///
  /// 分类规则：class 为 `hfp`/`low` 直接判定；或原生格式不达标
  /// （采样率/声道未知 0 时不算，避免误伤无法枚举规格的设备）。
  bool get isCall =>
      cls == 'hfp' ||
      cls == 'low' ||
      (rate > 0 && rate < 44100) ||
      (channels > 0 && channels < 2);

  /// 是否为可正常播放音乐的达标输出（与 [isCall] 互补）。
  bool get isGood => !isCall;
}

/// 解析引擎返回的 JSON 设备数组（`list_sinks`）；格式非法返回空列表。
List<_SinkDevice> _parseSinks(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final out = <_SinkDevice>[];
    for (final e in decoded) {
      if (e is! Map<String, dynamic>) continue;
      final id = e['id'];
      final name = e['name'];
      if (id is! String || name is! String || id.isEmpty) continue;
      out.add(
        _SinkDevice(
          id: id,
          name: name,
          rate: (e['rate'] as num?)?.toInt() ?? 0,
          channels: (e['channels'] as num?)?.toInt() ?? 0,
          isDefault: e['default'] == true,
          cls: _parseSinkClass(e['class']),
        ),
      );
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// 归一化引擎 `class` 字段：仅接受 a2dp|hfp|low|hdmi|usb|internal，其余
/// （缺字段/未知/空白）一律视为 `'unknown'`（兼容旧引擎 JSON）。
String _parseSinkClass(Object? raw) {
  if (raw is! String) return 'unknown';
  return switch (raw) {
    'a2dp' || 'hfp' || 'low' || 'hdmi' || 'usb' || 'internal' => raw,
    _ => 'unknown',
  };
}

/// 通话/低质设备确认弹窗的结果：
/// [useCall] = 用户仍显式选择该通话/低质设备；[useQuality] = 改用高质量。
enum _CallSinkChoice { useCall, useQuality }
