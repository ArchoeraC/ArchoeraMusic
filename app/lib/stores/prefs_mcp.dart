// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── MCP 接入（本地控制服务）偏好键（mcp. 前缀）──────────────────────
const mcpEnabledKey = 'mcp.enabled';
const mcpPortKey = 'mcp.port';
const mcpAccessKeyKey = 'mcp.accessKey';
const mcpAllowKeylessKey = 'mcp.allowKeyless';
const mcpAllowLanKey = 'mcp.allowLan';
const mcpShellEnabledKey = 'mcp.shellEnabled';
const mcpCapabilityPrefix = 'mcp.cap.';

/// 总开关默认关：本地控制服务需用户在设置中显式开启后才监听端口。
const bool defaultMcpEnabled = false;

/// 默认监听端口（高位非特权端口，普通用户可直接绑定）。
const int defaultMcpPort = 14559;

/// 端口合法范围：1024~65535。< 1024 在类 Unix 下需 root 绑定，
/// 与「所有系统调用均须普通用户可完成」的约束冲突，故一律收敛到非特权区间。
const int minMcpPort = 1024;
const int maxMcpPort = 65535;

/// 免密钥访问默认关：默认要求 `X-Archoera-Key`，降低本机其它程序误用风险。
const bool defaultMcpAllowKeyless = false;

/// 局域网暴露默认关：开启后绑定 `0.0.0.0`，需用户显式确认。
const bool defaultMcpAllowLan = false;

/// 命令行 shell 默认可用：`<exe> archoerashell …` 在终端操作（不打开 GUI）。
/// 关闭后带该子命令启动将直接报错退出。
const bool defaultMcpShellEnabled = true;

/// 各能力组独立开关默认关（「默认全部关闭」：仅总开关不会暴露任何能力）。
const bool defaultMcpCapability = false;

/// MCP 控制能力组 id（与 `McpCapability` 枚举一一对应；仅存字符串键）。
const List<String> mcpCapabilityIds = [
  'read',
  'playback',
  'queue',
  'search',
  'library',
  'preferences',
  'appearance',
  'collection',
  'history',
  'lyrics',
  'download',
];

/// 端口收敛到非特权区间。
int clampMcpPort(int value) => value.clamp(minMcpPort, maxMcpPort);

/// MCP 接入偏好：总开关 / 端口 / 访问密钥 / 免密钥开关 / 各能力组开关。
extension McpPrefs on AppPrefs {
  /// 本地控制服务总开关（默认关）。
  bool get mcpEnabled => data[mcpEnabledKey] as bool? ?? defaultMcpEnabled;

  /// 监听端口（收敛 1024~65535）。
  int get mcpPort =>
      clampMcpPort((data[mcpPortKey] as num?)?.toInt() ?? defaultMcpPort);

  /// 访问密钥（生成为 128-bit 十六进制；空串 = 尚未生成）。
  String get mcpAccessKey => (data[mcpAccessKeyKey] as String?)?.trim() ?? '';

  /// 是否允许免密钥访问（默认关）。
  bool get mcpAllowKeyless =>
      data[mcpAllowKeylessKey] as bool? ?? defaultMcpAllowKeyless;

  /// 是否允许局域网访问（默认关；开启后绑定 0.0.0.0，仍要求密钥）。
  bool get mcpAllowLan => data[mcpAllowLanKey] as bool? ?? defaultMcpAllowLan;

  /// 命令行 shell 是否可用（默认可用）。
  bool get mcpShellEnabled =>
      data[mcpShellEnabledKey] as bool? ?? defaultMcpShellEnabled;

  /// 能力组 [id] 是否启用（默认关）。
  bool mcpCapabilityEnabled(String id) =>
      data['$mcpCapabilityPrefix$id'] as bool? ?? defaultMcpCapability;

  AppPrefs copyWithMcpEnabled(bool value) =>
      AppPrefs(initialData: {...data, mcpEnabledKey: value});

  AppPrefs copyWithMcpPort(int value) =>
      AppPrefs(initialData: {...data, mcpPortKey: clampMcpPort(value)});

  AppPrefs copyWithMcpAccessKey(String value) =>
      AppPrefs(initialData: {...data, mcpAccessKeyKey: value});

  AppPrefs copyWithMcpAllowKeyless(bool value) =>
      AppPrefs(initialData: {...data, mcpAllowKeylessKey: value});

  AppPrefs copyWithMcpAllowLan(bool value) =>
      AppPrefs(initialData: {...data, mcpAllowLanKey: value});

  AppPrefs copyWithMcpShellEnabled(bool value) =>
      AppPrefs(initialData: {...data, mcpShellEnabledKey: value});

  AppPrefs copyWithMcpCapability(String id, bool value) =>
      AppPrefs(initialData: {...data, '$mcpCapabilityPrefix$id': value});
}
