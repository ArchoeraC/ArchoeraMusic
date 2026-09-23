// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 彩蛋（Easter Egg）框架。
///
/// 组成：
///   - [EasterEggEffect]：一个具名、可执行的彩蛋效果；
///   - [kEasterEggEffects]：全局彩蛋注册表（新增彩蛋往这里加）；
///   - [pickEasterEgg]：先按概率（默认 50%）决定是否触发，再按权重抽取；
///   - [EasterEggVisualHost]：把缩放/镜像/躲鼠标等效果施加到整棵 UI；
///   - [showEasterEggGate]：「千万别点」警告门（标题 + 警告 + 三个「确定」）。
///
/// 新增彩蛋：写一个 `Future<void> Function(EasterEggContext)`，在
/// [kEasterEggEffects] 追加一条 `EasterEggEffect` 即可。
library;

import 'dart:async' show Timer, unawaited;
import 'dart:io' show Platform, sleep;
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../app/app_quit.dart';
import '../app/theme_provider.dart';
import '../l10n/l10n.dart';
import '../services/playback/playback_notifier.dart';
import '../services/playback/playback_state.dart';
import '../widgets/dialogs/s_dialog.dart';
import '../widgets/player/s_controls.dart';
import 'easter_egg_visual_state.dart';

part 'easter_egg_effect.dart';
part 'easter_egg_visual.dart';
part 'easter_egg_effects.dart';
part 'easter_egg_gate.dart';
part 'effects/window_effects.dart';
part 'effects/app_effects.dart';
part 'effects/media_effects.dart';
