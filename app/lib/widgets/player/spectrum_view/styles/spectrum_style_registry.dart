// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 频谱可视化样式注册表。
///
/// 新增样式只需：
/// 1. 在 `styles/` 新建模块并实现 [SpectrumStyleRenderer]；
/// 2. 加进 [spectrumStyleRenderers]；
/// 3. 在 `prefs_player.dart` 的 `spectrumStyles` 与设置页下拉里登记同一个 id；
/// 4. `test/spectrum_style_registry_test.dart` 会守卫两处一致。
library;

import 'bars_spectrum_style.dart';
import 'spectrum_style.dart';
import 'wave_spectrum_style.dart';
import 'wave_up_spectrum_style.dart';

/// 内建频谱样式（顺序仅用于注册表遍历）。
const List<SpectrumStyleRenderer> spectrumStyleRenderers =
    <SpectrumStyleRenderer>[
      BarsSpectrumStyle(),
      WaveSpectrumStyle(),
      WaveUpSpectrumStyle(),
    ];

final Map<String, SpectrumStyleRenderer> _renderersById =
    <String, SpectrumStyleRenderer>{
      for (final style in spectrumStyleRenderers) style.id: style,
    };

/// id → 频谱样式；未知 id 回退 `bars`（旧数据/降级安全）。
SpectrumStyleRenderer spectrumStyleRendererFor(String id) =>
    _renderersById[id] ?? _renderersById['bars']!;
