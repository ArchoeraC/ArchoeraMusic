// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 回归：歌单头部动作不得在构建期修改 provider（首帧加载用户歌单须延后到
/// post-frame）。此前在 initState 直接 `ensureLoaded()` 会触发 Riverpod 的
/// 「Tried to modify a provider while the widget tree was building」断言。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/netease/apis_netease_caller.dart';
import 'package:archoera_music/services/netease/netease_api.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/stores/providers.dart';
import 'package:archoera_music/widgets/dialogs/playlist_manage.dart';

class _FakeApi extends NeteaseApi {
  _FakeApi() : super(ApisNeteaseCaller());

  @override
  Future<List<PlaylistItem>> userPlaylists(
    String uid, {
    int limit = 200,
  }) async => const [PlaylistItem(id: 'own1', name: '我的歌单')];
}

class _FakeAuth extends NeteaseAuthNotifier {
  @override
  NeteaseAccount? build() =>
      const NeteaseAccount(userId: 'u1', nickname: 'tester');
}

void main() {
  testWidgets('PlaylistHeaderActions 首帧不修改 provider', (tester) async {
    final container = ProviderContainer(
      overrides: [
        neteaseAuthProvider.overrideWith(_FakeAuth.new),
        neteaseApiProvider.overrideWithValue(_FakeApi()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: PlaylistHeaderActions(playlistId: 'own1')),
        ),
      ),
    );

    // 首帧（initState + build）不得抛 provider 修改断言。
    expect(tester.takeException(), isNull);
    // post-frame 触发 ensureLoaded；再走两帧不得抛错。
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });
}
