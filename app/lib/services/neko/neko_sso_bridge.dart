// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoAuth 原生客户端登录的深链桥。
///
/// NekoMusic 的 OIDC 回调最终由站内 HTTPS 完成页打开
/// `nekomusic://sso/complete?handoff=<一次性交接码>`；`SystemDeepLink` 把 URI
/// 交给 [DeepLinkRouter]，后者调用 [handleUri] 投递到这里，登录流程再拿
/// handoff 调 `/api/user/sso/claim` 换取 access token。
///
/// 深链本身不含 token；handoff 120 秒有效且只能领取一次。
library;

import 'dart:async';

/// NekoAuth 回调使用的 scheme（由 NekoMusic 服务端固定，不可改）。
const String kNekoSsoScheme = 'nekomusic';

/// `nekomusic://sso/complete?handoff=…` 的解析与等待队列。
class NekoSsoBridge {
  NekoSsoBridge._();

  static final StreamController<String?> _controller =
      StreamController<String?>.broadcast();

  /// 广播回调流（冷启动自动登录用；登录框等待走 [waitForHandoff]）。
  static Stream<String?> get handoffs => _controller.stream;

  /// 冷启动 / 早到的 handoff（[waitForHandoff] 先消费它，避免丢事件）。
  static String? _pending;

  /// 路由层入口：只接收 `nekomusic://sso/complete?handoff=…`。
  ///
  /// 返回 true 表示已识别并投递（其它 `nekomusic://` 路径忽略）。
  static bool handleUri(Uri uri) {
    if (uri.scheme != kNekoSsoScheme) return false;
    if (uri.host != 'sso') return false;
    final path = uri.path;
    if (path != '/complete' && path != 'complete') return false;
    final handoff = uri.queryParameters['handoff']?.trim() ?? '';
    if (handoff.isEmpty) return true; // 识别成功但没有可用交接码
    _pending = handoff;
    _controller.add(handoff);
    return true;
  }

  /// 等待下一个 handoff；超时或 [cancel] 完成时返回 null。
  ///
  /// 若在开始等待前已经收到（冷启动场景），直接返回缓冲值。
  static Future<String?> waitForHandoff({
    Duration timeout = const Duration(minutes: 5),
    Future<void>? cancel,
  }) {
    final buffered = _pending;
    if (buffered != null) {
      _pending = null;
      return Future<String?>.value(buffered);
    }

    final completer = Completer<String?>();
    Timer? timer;
    StreamSubscription<String?>? sub;

    void finish(String? value) {
      if (completer.isCompleted) return;
      timer?.cancel();
      unawaited(sub?.cancel());
      completer.complete(value);
    }

    // 必须可取消：关闭登录框后不能留下监听，否则下一次登录的 handoff 会被
    // 旧流程抢走（也会拖住 `nekomusic://` 的注销）。
    sub = _controller.stream.listen(finish);
    timer = Timer(timeout, () => finish(null));
    cancel?.then((_) => finish(null));
    return completer.future;
  }

  /// 取走尚未消费的 handoff（冷启动自动登录用）。
  static String? takePending() {
    final h = _pending;
    _pending = null;
    return h;
  }

  /// 丢弃尚未消费的 handoff（用户取消 / 重新发起登录时调用）。
  static void clearPending() => _pending = null;

  /// 测试用：重置缓冲（不关闭广播流）。
  static void debugReset() => _pending = null;
}
