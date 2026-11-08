// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 音源 / 收藏注册表回归：防止「dynamic ref + AppPrefs 扩展 getter」与
/// 「authSignal 以 dynamic 暴露」两类运行时错误再次让页面白屏。
///
/// 背景（2026-09-23 修复）：
/// - `_NekoCollection.enabled` / `_NekoSource.enabled` 曾以 `dynamic ref`
///   调用 `ref.read(appPrefsProvider).nekoEnabled`（扩展 getter）。dynamic 调用
///   不走扩展方法 → `NoSuchMethodError: Class 'AppPrefs' has no instance getter
///   'nekoEnabled'` → 「我喜欢 / 收藏 / 搜索」整页白屏。
/// - `CollectionPlatform.authSignal` 曾声明为 `dynamic`，`ref.listen` 因而以
///   `T=dynamic` 实例化，Riverpod 订阅实现类型判定失败 → `_listenedElement`
///   NoSuchMethodError → 页面白屏。现类型为 `ProviderListenable<Object?>?`。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/services/source/source_platform.dart';
import 'package:archoera_music/widgets/dialogs/collection_platform.dart';

/// 不读写磁盘偏好的测试用 prefs controller。
class _NoSideEffectsPrefsNotifier extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

/// 固定偏好值的测试用 prefs controller。
class _FixedPrefsNotifier extends AppPrefsNotifier {
  _FixedPrefsNotifier(this.prefs);

  final AppPrefs prefs;

  @override
  AppPrefs build() => prefs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer scoped() => ProviderContainer.test(
    overrides: [appPrefsProvider.overrideWith(_NoSideEffectsPrefsNotifier.new)],
  );

  test('collectionPlatforms/sourcePlatforms 读取 enabled 不抛（dynamic ref + 扩展 getter）', () {
    final c = scoped();
    // 修复前：_NekoCollection.enabled 动态读扩展 getter → NoSuchMethodError
    // → collectionPlatforms 抛错 → 我喜欢/收藏页白屏。
    expect(() => collectionPlatforms(c), returnsNormally);
    expect(
      collectionPlatforms(c).map((p) => p.source),
      containsAll(<String>['netease', 'kugou', 'qqmusic']),
    );
    // 修复前：_NekoSource.enabled 同理 → sourcePlatforms 抛错 → 搜索页白屏。
    expect(() => sourcePlatforms(c), returnsNormally);
    expect(
      sourcePlatforms(c).map((p) => p.source),
      containsAll(<String>['netease', 'kugou', 'qqmusic']),
    );
    // 聚合搜索同样遍历 enabled(ref)。
    expect(() => aggregateSources(c), returnsNormally);
    expect(
      aggregateSources(c),
      containsAll(<String>['netease', 'kugou', 'qqmusic']),
    );
  });

  test('运行期 URL 过期恢复能力只在会过期直链的源上开启', () {
    // NT 的 song_url 是带时效签名的 CDN 直链；本地文件不参与。
    expect(sourcePlatform('netease').urlExpiryRecoverable, isTrue);
    expect(sourcePlatform('local').urlExpiryRecoverable, isFalse);
  });

  test('authSignal 以 ProviderListenable 暴露，可被容器 listen', () {
    final c = scoped();
    for (final p in collectionPlatforms(c)) {
      final signal = p.authSignal;
      if (signal == null) continue;
      // 修复前 authSignal 为 dynamic，c.listen 动态派发 → 订阅 impl 为 null
      // → NoSuchMethodError（_listenedElement）。
      final sub = c.listen(signal, (_, _) {});
      sub.close();
    }
  });

  test('默认音源偏好作用于收藏 / 搜索默认平台', () {
    final c = ProviderContainer.test(
      overrides: [
        appPrefsProvider.overrideWith(
          () => _FixedPrefsNotifier(AppPrefs().copyWithDefaultSource('kugou')),
        ),
      ],
    );
    expect(preferredCollectionSource(c), 'kugou');
    expect(preferredSearchSource(c), 'kugou');
    expect(defaultLikedPlatform(c), 'kugou');
  });

  test('默认音源 auto / 未启用源回退到各页历史默认值', () {
    final auto = ProviderContainer.test(
      overrides: [
        appPrefsProvider.overrideWith(
          () => _FixedPrefsNotifier(
            AppPrefs().copyWithDefaultSource(autoDefaultSource),
          ),
        ),
      ],
    );
    expect(preferredCollectionSource(auto), 'netease');
    expect(preferredSearchSource(auto), 'netease');

    final disabledNeko = ProviderContainer.test(
      overrides: [
        appPrefsProvider.overrideWith(
          () => _FixedPrefsNotifier(AppPrefs().copyWithDefaultSource('neko')),
        ),
      ],
    );
    // Neko 默认关闭：设置里残留的 neko 不应被当作可用默认源。
    expect(preferredCollectionSource(disabledNeko), 'netease');
    expect(preferredSearchSource(disabledNeko), 'netease');
  });
}
