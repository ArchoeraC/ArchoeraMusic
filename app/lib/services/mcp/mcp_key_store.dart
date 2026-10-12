// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// MCP 访问密钥存储（SEC-10）：凭据保险库为权威存储。
///
/// 历史实现把密钥以明文写入 `prefs.json`（`mcp.accessKey`）——文件嘈杂且会
/// 随偏好导出/备份外泄。现改为：
///   - GUI 写入一律经凭据保险库（vault，uid=`mcp:accessKey`，AES 加密落盘）；
///   - `prefs.json` 不再包含明文密钥（启动时一次性迁移并清除历史值）；
///   - 进程内保留同步缓存（[cached]），供偏好 getter 与服务配置同步读取。
///
/// 健壮性：所有 vault 调用均包裹 try/catch——vault 不可用（未构建/未初始化/
/// 口令模式未解锁）时回退历史明文值或留空（由服务按需重新生成），绝不崩溃、
/// 也不让 MCP 在无密钥下静默暴露。
library;

import 'dart:convert';
import 'dart:io';

import '../log/log.dart';
import '../security/vault_process.dart';

/// MCP 访问密钥的内存缓存 + 凭据保险库读写。
class McpKeyStore {
  McpKeyStore._();

  /// 凭据保险库条目 uid（GUI 权威存储）。
  static const String uidFor = 'mcp:accessKey';

  /// `prefs.json` 中的历史明文键（仅用于一次性迁移与兜底读取）。
  static const String legacyPrefsKey = 'mcp.accessKey';

  static String? _cached;

  /// 当前进程内缓存的密钥（尚未加载或本机无密钥时为 null）。
  static String? get cached => _cached;

  /// 设置进程内缓存（[AppPrefs.setMcpAccessKey] 同步写入，供 getter 立即可见）。
  static void setCached(String value) => _cached = value;

  /// 清空进程内缓存（销毁/登出敏感数据后调用）。
  static void reset() => _cached = null;

  /// 加载密钥：优先 vault；无条目则迁移历史 `prefs.json` 明文（成功即清除）。
  ///
  /// vault 不可用/报错时不抛出，回退历史明文值（如有）；两者皆无则清空缓存，
  /// 由调用方（[McpService]）按需重新生成新密钥。
  static Future<void> load(String dataDir) async {
    final legacy = readLegacy(dataDir);
    String? fromVault;
    try {
      fromVault = await VaultProcess.get(dataDir, uidFor);
    } catch (e) {
      Log.w('mcp', '读取凭据保险库中的 MCP 密钥失败，回退历史值：$e');
    }
    final vaultKey = _decode(fromVault);
    if (vaultKey != null && vaultKey.isNotEmpty) {
      _cached = vaultKey;
      // 历史明文仍在（此前迁移未清干净）：vault 权威，直接剔除。
      if (legacy != null) clearLegacy(dataDir);
      return;
    }
    if (legacy != null && legacy.isNotEmpty) {
      _cached = legacy;
      try {
        await VaultProcess.set(dataDir, uidFor, legacy);
        clearLegacy(dataDir); // 迁移成功：移除 prefs.json 明文
      } catch (e) {
        Log.w('mcp', 'MCP 密钥迁移入凭据保险库失败（保留库外历史值）：$e');
      }
      return;
    }
    _cached = null;
  }

  /// 持久化密钥到 vault（异步写穿；失败仅告警，绝不抛出）。
  ///
  /// 内存缓存由 [setCached] 同步更新，故 vault 写入失败不会让当前会话失去
  /// 密钥；`prefs.json` 也已不再承载明文。
  static Future<void> persist(String dataDir, String value) async {
    try {
      await VaultProcess.set(dataDir, uidFor, value);
    } catch (e) {
      Log.w('mcp', 'MCP 密钥写入凭据保险库失败（仅内存生效）：$e');
    }
  }

  /// 从 `prefs.json` 读取历史明文密钥（文件缺失/损坏/无键返回 null）。
  static String? readLegacy(String dataDir) {
    try {
      final f = File('$dataDir/prefs.json');
      if (!f.existsSync()) return null;
      final json = jsonDecode(f.readAsStringSync());
      if (json is Map) {
        final v = json[legacyPrefsKey];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
    } catch (_) {
      // 文件缺失/损坏：视为无历史值
    }
    return null;
  }

  /// 移除 `prefs.json` 中的历史明文密钥（幂等；GUI 已不再写入）。
  static void clearLegacy(String dataDir) {
    try {
      final f = File('$dataDir/prefs.json');
      if (!f.existsSync()) return;
      final json = jsonDecode(f.readAsStringSync());
      if (json is! Map || !json.containsKey(legacyPrefsKey)) return;
      json.remove(legacyPrefsKey);
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
    } catch (_) {
      // 清理失败不阻断：后续 [AppPrefs.save] 亦会剥离该键
    }
  }

  /// vault `get` 返回 base64 载荷；解码为明文（空/损坏返回 null）。
  static String? _decode(String? raw) {
    if (raw == null) return null;
    try {
      return utf8.decode(base64Decode(raw)).trim();
    } catch (_) {
      return null;
    }
  }
}
