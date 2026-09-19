// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// deep link URI → 应用动作（scheme `archoera://`）。
///
/// 语法（主机名 = 动作，路径/查询为参数）：
///   `archoera://player`                打开全屏播放页
///   `archoera://search?q=<keyword>`    打开搜索
///   `archoera://album/<id>`            打开流媒体专辑详情
///   `archoera://playlist/<id>`         打开流媒体歌单详情
///   `archoera://artist/<id>`           打开流媒体歌手详情
///
/// 启动期（播放现场恢复完成前）到达的链接先缓冲，[markReady] 后统一派发。
library;

import 'dart:async';

import '../../app/router.dart';
import '../platform/system_deep_link.dart';

class DeepLinkRouter {
  DeepLinkRouter(this.deepLink);

  final SystemDeepLink deepLink;

  StreamSubscription<Uri>? _sub;
  final _pending = <Uri>[];
  bool _ready = false;

  /// 订阅桥接 deep link 流。
  void start() {
    _sub = deepLink.uris.listen(_onUri);
  }

  /// 启动完成后调用：派发启动期缓冲的链接。
  void markReady() {
    if (_ready) return;
    _ready = true;
    final pending = List<Uri>.of(_pending);
    _pending.clear();
    for (final u in pending) {
      _dispatch(u);
    }
  }

  void _onUri(Uri uri) {
    if (!_ready) {
      _pending.add(uri);
      return;
    }
    _dispatch(uri);
  }

  void _dispatch(Uri uri) {
    if (uri.scheme != 'archoera') return;
    final path = uri.pathSegments;
    String seg(int i) =>
        i < path.length ? Uri.decodeComponent(path[i]) : '';
    switch (uri.host) {
      case 'player':
        openPlayerPage();
      case 'search':
        final q = uri.queryParameters['q'] ?? '';
        appRouter.go('/search?q=${Uri.encodeComponent(q)}');
      case 'album':
        if (seg(0).isNotEmpty) {
          appRouter.go('/streaming/album/${Uri.encodeComponent(seg(0))}');
        }
      case 'playlist':
        if (seg(0).isNotEmpty) {
          appRouter.go('/streaming/playlist/${Uri.encodeComponent(seg(0))}');
        }
      case 'artist':
        if (seg(0).isNotEmpty) {
          appRouter.go('/streaming/artist/${Uri.encodeComponent(seg(0))}');
        }
    }
    // 收到链接即置前窗口（次实例转发场景）。
    unawaited(deepLink.activateWindow());
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }
}
