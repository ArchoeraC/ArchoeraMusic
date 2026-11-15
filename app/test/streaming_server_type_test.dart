// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流媒体服务器类型的默认端口与表单提示：端口 / 名称占位符必须跟随用户
/// 选择的类型，而不是固定写死 Subsonic / Jellyfin / Navidrome。
library;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/streaming/streaming_types.dart';

void main() {
  test('默认端口按服务器类型区分', () {
    expect(StreamingServerType.subsonic.defaultPort, 4040);
    expect(StreamingServerType.airsonic.defaultPort, 4040);
    expect(StreamingServerType.navidrome.defaultPort, 4533);
    expect(StreamingServerType.gonic.defaultPort, 4747);
    expect(StreamingServerType.lms.defaultPort, 9000);
    expect(StreamingServerType.jellyfin.defaultPort, 8096);
    expect(StreamingServerType.emby.defaultPort, 8096);
    expect(StreamingServerType.songloft.defaultPort, 58091);
  });

  test('名称占位符 / 端口提示使用所选类型', () {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(
      l10n.streamingServerNamePlaceholder(type: 'Songloft'),
      contains('Songloft'),
    );
    expect(
      l10n.streamingServerPortNote(port: '58091', type: 'Songloft'),
      allOf(contains('58091'), contains('Songloft')),
    );
  });
}
