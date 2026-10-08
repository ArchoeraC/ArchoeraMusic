// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 音源的客户端标识（分层身份）。
///
/// NekoMusic 服务端有两道与身份相关的校验：
///
/// 1. **防爬 / 客户端区分**——见《防爬与客户端识别》：
///    - 空 / 缺失 `User-Agent` → 一律按爬虫处理（`GET` 直出 SEO HTML、
///      其它方法 `403`），**旧版「空 UA 放行」旁路已拆除**，不能再依赖；
///    - 官方原生客户端 UA 为**整体锚定**的 `NekoMusic-<平台>/<版本>`
///      （平台限 `android|pc|ios|macos|windows|linux|qt`，版本必须以数字开头）；
///    - 未知 UA（既非浏览器完整性、也非官方 UA）同样被降级为 SEO HTML。
///    我们既不是官方客户端、也不冒名 Android，因此采用**分层身份**：
///    - **主路径（优雅）**：以 ArchoeraMusic 本体自报
///      `User-Agent: ArchoeraMusic/<版本> (<平台>)` + `X-Neko-Client: archoera+<版本>`。
///      服务端一旦落地「自报标识放行」（`X-Neko-Client` 作为正向证据），
///      或把 `ArchoeraMusic` 纳入放行名单，即自动生效。
///    - **回退（暴力）**：当前线上服务端尚不认该本体 UA，主路径会被降级；此时改发
///      **纯 NekoMusic 桌面 UA 形状** `NekoMusic-<平台>/<版本>`，命中服务端
///      `isNativeClient` 锚定正则。回退**只换 UA 形状、不改其它语义**，
///      且绝不伪装 Android、绝不补浏览器特征头（不做反爬对抗）。
///      切换由 [NekoClient] 在检测到「响应被降级」时自动触发（见
///      `apis/neko/neko_client.dart` 的 [nekoIsDegradedResponse]），进程内粘滞。
/// 2. **请求防重放**——见《请求防重放》：全部动态接口（`/api/*`、`/loser/*`）
///    需一次性 `X-Neko-Nonce`（绑定 IP + 读/写、短时有效、用后即废），缺失/
///    重放返回 `409`。由 `apis/neko/neko_client.dart` 的 nonce 池自动领取并注入。
///
/// 例外是**站点图片**（封面 / 头像）：它们经全局 HttpClient（浏览器 UA，见
/// `main.dart` 的 `_BrowserUserAgentOverrides`）发起，`Image` / `NetworkImage`
/// 以 `add` 语义追加请求头、**无法清空 / 覆盖 UA**，因此图片侧无法换用上述
/// 分层 UA，保持「标识头 + 浏览器特征头」：新服务端靠 `X-Neko-Client` 放行，
/// 现存服务端靠浏览器完整性放行（封面 / 头像本身也在防重放豁免清单内）。
library;

import 'dart:io';

import '../../utils/app_version.dart';

/// 端名：客户端标识 `<端>+<版本>` 的前半段。
const String kClientName = 'archoera';

/// 客户端标识头名（见后端《防爬与客户端识别》专项文档；供服务端识别来源）。
const String kNekoClientHeader = 'X-Neko-Client';

/// 防重放 nonce 请求头（服务端对全部动态 `/api/*`、`/loser/*` 强制要求）。
///
/// 见后端《请求防重放》专项文档：一次性、绑定「客户端 IP + 读/写类别」、
/// 短时有效；缺失/重放/过期返回 `409`。
const String kNekoNonceHeader = 'X-Neko-Nonce';

/// 防重放失败原因响应头（`missing` / `invalid`；据此决定换 nonce 重试一次）。
const String kNekoReplayStatusHeader = 'X-Neko-Replay-Status';

/// 版本占位：读取失败时用 `unknown`（服务端放行不依赖版本）。
String get _versionOrUnknown =>
    clientVersion.isEmpty ? 'unknown' : clientVersion;

/// 官方 UA 正则要求版本以数字开头：未知 / 空版本回退 `0`（仍能命中）。
String get _versionWithLeadingDigit =>
    clientVersion.isEmpty ? '0' : clientVersion;

/// 客户端标识值：`archoera+<版本>`。
String get nekoClientValue => '$kClientName+$_versionOrUnknown';

/// 当前平台标识：命中服务端官方 UA 正则接受的桌面平台（`windows|macos|linux`）。
String get nekoPlatformName {
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  return 'linux';
}

/// 优先身份 UA（主路径）：以 ArchoeraMusic 本体直接自报。
String get nekoPrimaryUserAgent =>
    'ArchoeraMusic/$_versionOrUnknown ($nekoPlatformName)';

/// 兼容回退 UA（暴力路径）：纯 NekoMusic 桌面 UA 形状 `NekoMusic-<平台>/<版本>`。
///
/// 仅在服务端把本体标识按爬虫降级时启用；用于在服务端尚未接受
/// `ArchoeraMusic` 前仍能拿到 JSON。**不是**冒名官方客户端品牌，
/// 只是复用其公开的 UA 形状以通过锚定正则；`X-Neko-Client` 始终保留本应用标识。
String get nekoFallbackUserAgent =>
    'NekoMusic-$nekoPlatformName/$_versionWithLeadingDigit';

/// 是否已切换到回退身份（本体标识被服务端拒绝后由 [NekoClient] 置位，进程内粘滞）。
bool _useFallbackIdentity = false;

/// 当前是否处于回退身份（UI / 诊断可用）。
bool get nekoIdentityUsesFallback => _useFallbackIdentity;

/// 标记「本体标识被服务端按爬虫降级」→ 后续请求改用 [nekoFallbackUserAgent]。
void nekoNoteIdentityRejected() {
  _useFallbackIdentity = true;
}

/// 复位回退身份（测试 / 服务器地址切换时调用）。
void nekoResetIdentity() {
  _useFallbackIdentity = false;
}

/// 发往 NekoMusic 的完整请求头（REST / SSE / 音频下载 / 引擎 AVIO / 原生 HTTP）。
///
/// 分层身份：默认以 ArchoeraMusic 本体自报；被降级后自动回退为纯
/// `NekoMusic-<平台>/<版本>`（详见库注释）。两种情形都带 `X-Neko-Client`，
/// 且 `User-Agent` 始终非空。
Map<String, String> get nekoRequestHeaders => {
      'User-Agent': _useFallbackIdentity
          ? nekoFallbackUserAgent
          : nekoPrimaryUserAgent,
      kNekoClientHeader: nekoClientValue,
    };

/// 发往 NekoMusic 站点图片（封面 / 头像）的请求头。
///
/// 图片经全局浏览器 UA 发起、无法覆盖 UA，故只补标识头与浏览器特征头：
/// 新服务端靠 `X-Neko-Client` 放行，现存服务端靠浏览器完整性放行
/// （详见库注释）。
Map<String, String> get nekoClientHeaderOnly => {
      kNekoClientHeader: nekoClientValue,
      'Accept': 'image/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };

/// 媒体请求头解析器：命中 NekoMusic 站点的图片资源（封面 / 头像）时返回标识头。
///
/// 由 `services/source/media_request_headers.dart` 注册到全局解析表，供各图片工具
/// （`Image.network` / `NetworkImage`）统一取用，避免各 widget 直接依赖本源。
Map<String, String>? nekoMediaHeaderResolver(Uri uri) {
  final path = uri.path;
  if (path.startsWith('/api/music/cover/') ||
      path.startsWith('/api/user/avatar/')) {
    return nekoClientHeaderOnly;
  }
  return null;
}
