// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 构建时间展示（设置页「版本」右侧）：
// - 只认编译期 `--dart-define=ARCHOERA_BUILD_TIME`（CI 手动派发 / Nightly
//   注入）；本地构建与 tag 发版不注入 → 不展示；
// - 展示格式固定 `yyyy-MM-dd HH:mm`，不依赖 intl 区域数据。

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/utils/app_version.dart';

void main() {
  test('未注入构建时间：getter 为 null、展示文本为空串', () {
    // 测试进程没有 --dart-define=ARCHOERA_BUILD_TIME。
    expect(buildTime, isNull);
    expect(buildTimeLabel, isEmpty);
  });

  test('构建时间格式化：补零到 yyyy-MM-dd HH:mm', () {
    expect(formatBuildTime(DateTime(2026, 11, 19, 8, 5)), '2026-11-19 08:05');
    expect(formatBuildTime(DateTime(2026, 1, 2, 23, 59)), '2026-01-02 23:59');
  });
}
