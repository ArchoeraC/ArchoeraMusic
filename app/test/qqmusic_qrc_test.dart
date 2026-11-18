// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM QRC 歌词解密的纯单元用例（**不联网**）。
///
/// 真实云端直连用例已移除：无登录 cookie 时 VIP 曲目一律拒绝，出口/风控
/// 差异还会变成假红或长时间等待。
library;

import 'package:archoera_music/apis/qqmusic/core/qrc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('qmDecryptQrc：无数据抛错', () {
    expect(() => qmDecryptQrc(''), throwsA(anything));
  });
}
