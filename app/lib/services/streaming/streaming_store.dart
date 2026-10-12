// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流媒体服务器配置持久化（对齐 shared/types/streaming.ts StreamingApi）。
///
/// 配置文件 `streaming_servers.json` 只存**非敏感**字段（host/port/username 等）；
/// 凭据（password / accessToken）经凭据保险库（vault）加密存储，
/// 条目 uid = `streaming:<serverId>`。与 VaultSessionStore 同模式：
///   内存缓存即时可见（write-through），vault 持久化经串行队列异步执行。
///
/// 迁移：旧版本明文密码在首次 [load] 时发现 → 先入 vault（成功才覆写文件
/// 去密）；vault 不可用时降级——不静默丢弃凭据，[save] 回写含凭据旧形态
/// 并告警（等同迁移前状态，待 vault 可用后下次启动迁移）。
library;

import 'dart:convert';
import 'dart:io';

import '../../stores/data_dir.dart';
import '../security/vault_kdf.dart';
import '../security/vault_process.dart';
import 'streaming_types.dart';
import '../../utils/safe_file.dart';

/// 服务器配置存储。
class StreamingStore {
  StreamingStore._();

  /// 测试注入：非空时替代 [resolveDataDir]（凭据路径与 vault 查找同步生效）。
  static String dataDirOverride = '';

  /// 未初始化时的默认加密方案（与 [VaultSessionStore] 默认一致，crypto 推荐；
  /// 测试可注入 'file' 验证文件密钥分支）。
  static String defaultScheme = 'crypto';

  static String _dir() =>
      dataDirOverride.isNotEmpty ? dataDirOverride : resolveDataDir();

  /// 存储文件路径：数据目录（`~/.local/share/ArchoeraMusic`）。
  static String get filePath => '${_dir()}/streaming_servers.json';

  /// vault 条目前缀：`streaming:<serverId>`。
  static const String _uidPrefix = 'streaming:';

  /// 口令校验/恢复态探测探针 uid：仅用于单次握手，不对应任何真实服务器
  /// （get 返回 null）；避免为探测专门引入新的 vault 命令。
  static const String _probeUid = 'streaming:__probe__';

  /// vault 持久化串行队列（防乱序覆盖；与 VaultSessionStore 同模式）。
  static Future<void> _queue = Future.value();

  /// 凭据内存缓存（按文件路径隔离，write-through）：serverId → {password, accessToken}。
  ///
  /// **懒加载语义**：仅当 [loadSecret] 真正解密（或用户在表单携带凭据保存）
  /// 后才写入；id 不在表中 = 未知（未加载，[save] 不得覆盖/删除其 vault 条目）；
  /// 空 map = 显式清空（[clearSecret] / 新增无凭据服务器 → 落库删除）。
  static final Map<String, Map<String, Map<String, String>>> _secretCache = {};

  /// vault 不可用告警只打一次（load/save 高频路径防刷屏）。
  static bool _warnedVaultDown = false;

  /// 设备因子缺失（m2a device.key 丢失）：需恢复码解锁。
  static bool _needsRecovery = false;

  /// m1/m2a 解锁口令（内存持有，仅用于 serve 握手；绝不持久化/写盘；
  /// 应用重启后需重新输入）。
  static String? _sessionPassword;

  /// m2a 恢复码（device.key 缺失时经恢复槽解锁；内存持有，仅用于握手）。
  static String? _sessionRecoveryCode;

  /// m1/m2a 模式且本会话尚未解锁（[preloadSecrets] 检测到需口令模式、
  /// 无 [unlockWithPassword] 先行解锁时置位）——需用户输入口令解锁。
  static bool _needsPassword = false;

  /// 最近一次 [preloadSecrets] 探测到的 vault 模式（`crypto`/`m1`/`m2a`/`m2b`；
  /// 未初始化/不可用为 null）——供解锁门区分「m2a 提供恢复码入口」。
  static String? _mode;

  /// 同 [VaultSessionStore.needsRecovery]（流媒体凭据侧，启动预取后查询）。
  static bool get needsRecovery => _needsRecovery;

  /// vault 模式（`crypto` | `m1` | `m2a` | `m2b`；未探测/不可用为 null）。
  static String? get mode => _mode;

  /// m1/m2a 模式本会话未解锁：需 [unlockWithPassword] 输入口令。
  static bool get needsPassword => _needsPassword;

  /// m1/m2a 口令解锁（每次会话启动后调用）：用口令解锁并**惰性**解密凭据
  /// （[loadSecret] 按需取用），不批量解密。成功后 [needsPassword] 复位；
  /// 口令仅内存持有（[_sessionPassword]）。
  static Future<bool> unlockWithPassword(String password) async {
    if (!VaultProcess.available) return false;
    _sessionPassword = password;
    _sessionRecoveryCode = null;
    try {
      await preloadSecrets();
      if (_needsPassword) return false;
      final mode = await VaultProcess.mode(_dir());
      if (mode == 'm1' || mode == 'm2a') {
        // 单次握手校验口令（固定探针 uid，不含任何真实凭据）：
        // 口令错误 → 握手 GCM 认证失败抛异常，据此返回 false。
        await VaultProcess.get(_dir(), _probeUid, password: password);
      }
      return true;
    } on VaultNeedRecoveryException catch (e) {
      _needsRecovery = true;
      _needsPassword = true;
      stderr.writeln('[vault] 流媒体口令解锁需恢复：$e');
      return false;
    } catch (e) {
      if (await _needsCredentialMode()) _needsPassword = true;
      stderr.writeln('[vault] 流媒体口令解锁失败：$e');
      return false;
    } finally {
      if (_needsPassword) _sessionPassword = null; // 解锁失败：口令作废
    }
  }

  /// 恢复解锁（m2a device.key 缺失）：用恢复码**单次握手**验证（固定探针
  /// uid，不批量解密）并缓存为会话凭据——后续 [loadSecret] 惰性解密。
  /// 成功后 [needsRecovery] 复位。
  static Future<bool> recover(String recoveryCode) async {
    if (!VaultProcess.available) return false;
    try {
      await VaultProcess.get(_dir(), _probeUid, recoveryCode: recoveryCode);
      _sessionRecoveryCode = recoveryCode;
      _sessionPassword = null;
      _needsRecovery = false;
      return true;
    } on VaultNeedRecoveryException catch (e) {
      stderr.writeln('[vault] 流媒体恢复码仍不可解锁：$e');
      return false;
    } catch (e) {
      stderr.writeln('[vault] 流媒体恢复码解锁失败：$e');
      return false;
    }
  }

  /// 重键 Argon2id 强度（m1/m2a）：以 [preset] 对应的 m/t/p 重新封装口令槽，
  /// **主密钥 K 与全部流媒体凭据保持不变**（无数据丢失）。
  /// [password] 为当前解锁口令（默认取本会话已解锁口令 [_sessionPassword]）；
  /// m2a 须 device.key 可用，否则 vault 返回 `NEED_RECOVERY`（经 [VaultException] 上抛）。
  static Future<void> setKdfPreset(String preset, {String? password}) async {
    final p = vaultKdfPresetById(preset);
    await VaultProcess.setKdf(_dir(),
        m: p.mKiB, t: p.t, p: p.p, password: password ?? _sessionPassword);
  }

  /// 重置静态状态（测试隔离用；生产不调用）。
  static void resetForTest() {
    dataDirOverride = '';
    defaultScheme = 'crypto';
    _secretCache.clear();
    _queue = Future.value();
    _warnedVaultDown = false;
    _needsRecovery = false;
    _needsPassword = false;
    _mode = null;
    _sessionPassword = null;
    _sessionRecoveryCode = null;
  }

  /// 等待持久化队列排空（登出/退出前落盘确认；测试断言用）。
  static Future<void> flush() => _queue;

  static void _enqueue(Future<bool> Function() op) {
    _queue = _queue.then((_) => op()).catchError((Object e) {
      stderr.writeln('[vault] 流媒体凭据持久化失败：$e');
      return false;
    });
  }

  static void _warnVaultDown() {
    if (_warnedVaultDown) return;
    _warnedVaultDown = true;
    stderr.writeln('[vault] 凭据保险库不可用：流媒体服务器凭据无法加密存储');
  }

  static String _uidFor(String serverId) => '$_uidPrefix$serverId';

  static Map<String, String>? _decodeSecret(String raw) {
    try {
      final decoded = jsonDecode(utf8.decode(base64Decode(raw)));
      if (decoded is Map<String, dynamic>) {
        return decoded.map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (_) {}
    return null;
  }

  /// 启动预取：仅做 vault 惰性初始化与模式探测（口令/恢复态），
  /// **绝不逐服务器解密**——凭据由 [loadSecret] 在真正需要时按需解密，
  /// 避免启动即把全部流媒体凭据明文进 Dart 堆（SEC-03）。
  /// vault 不可用 / 未初始化时惰性 init；异常静默降级（load 返回空凭据）。
  /// m1/m2a 模式：未 [unlockWithPassword] 前仅置 [needsPassword]（不告警
  /// vault down——区别对待「需口令解锁」与「vault 不可用」）。
  /// m2a/m2b：单次握手探测设备因子是否缺失（[needsRecovery]），
  /// 仍不涉及任何真实凭据条目。
  static Future<void> preloadSecrets() async {
    try {
      if (!VaultProcess.available) return;
      if (!await VaultProcess.isInitialized(_dir())) {
        // 惰性初始化：默认 crypto（LEGACY 单因子推荐）；defaultScheme='file'
        // 走文件密钥模式（免 OS 钥匙串）——设置页选择后冷切重启生效。
        // 历史 'vault'（2-of-2，已移除）回落 crypto。
        if (defaultScheme == 'file') {
          await VaultProcess.initFile(_dir());
        } else {
          await VaultProcess.initCrypto(_dir());
        }
      }
      final mode = await VaultProcess.mode(_dir());
      _mode = mode;
      if ((mode == 'm1' || mode == 'm2a') &&
          _sessionPassword == null &&
          _sessionRecoveryCode == null) {
        _needsPassword = true;
        return;
      }
      _needsPassword = false;
      // m2a/m2b：固定探针 uid 单次握手探测设备因子缺失/恢复态
      // （device.key 丢失 → NEED_RECOVERY）。其余模式无需探测。
      if (mode == 'm2a' || mode == 'm2b') {
        await VaultProcess.get(_dir(), _probeUid,
            password: _sessionPassword, recoveryCode: _sessionRecoveryCode);
      }
    } on VaultNeedRecoveryException catch (e) {
      // m2a device.key 缺失：可恢复状态，UI 应弹恢复流而非静默降级
      _needsRecovery = true;
      stderr.writeln('[vault] 流媒体凭据需恢复码解锁：$e');
    } catch (e) {
      // m1/m2a：口令错误/锁定（GCM 认证拒绝、退避拒绝）→ 保持
      // needsPassword 待重试（unlockWithPassword 据此返回 false，不误报成功）；
      // 其余不可用（二进制缺失等）→ 告警降级。
      if (await _needsCredentialMode()) {
        _needsPassword = true;
      } else {
        _warnVaultDown();
      }
      stderr.writeln('[vault] 流媒体凭据预取失败：$e');
    }
  }

  /// 当前 vault 是否为 m1/m2a（需口令解锁；解锁失败时区分「口令错误待重试」
  /// 与「vault 不可用」）。读取失败视为非口令模式（走告警降级）。
  static Future<bool> _needsCredentialMode() async {
    try {
      final mode = await VaultProcess.mode(_dir());
      return mode == 'm1' || mode == 'm2a';
    } catch (_) {
      return false;
    }
  }

  /// 读取服务器列表 + 当前激活服务器 id。
  ///
  /// 凭据**仅来自已加载的内存缓存**（[loadSecret] 按需解密）——未加载时为
  /// 空 password / null accessToken（元数据完整）。发现旧明文自动迁移：
  /// 先入 vault，成功才覆写文件去密。保持同步以兼容 provider 首帧读取。
  static ({List<StreamingServerConfig> servers, String? activeServerId}) load() {
    final cache = _secretCache.putIfAbsent(filePath, () => {});
    var pendingMigration = false;
    try {
      final text = SafeFile.readString(filePath);
      if (text == null) return (servers: const [], activeServerId: null);
      final json = jsonDecode(text);
      if (json is Map) {
        final raw = json['servers'];
        final activeServerId = json['activeServerId']?.toString();
        if (raw is List) {
          final servers = <StreamingServerConfig>[];
          for (final e in raw.whereType<Map>()) {
            final m = e.cast<String, dynamic>();
            final cfg = StreamingServerConfig.fromJson(m);
            final legacyPassword = m['password']?.toString();
            final legacyToken = m['accessToken']?.toString();
            final hasLegacy = (legacyPassword?.isNotEmpty ?? false) ||
                (legacyToken?.isNotEmpty ?? false);
            if (hasLegacy) {
              // 旧明文（vault 未接管前）：内存采用并标记迁移
              cache[cfg.id] = {
                if (legacyPassword != null && legacyPassword.isNotEmpty)
                  'password': legacyPassword,
                if (legacyToken != null && legacyToken.isNotEmpty)
                  'accessToken': legacyToken,
              };
              servers.add(cfg.copyWith(
                password: legacyPassword ?? '',
                accessToken: legacyToken,
              ));
              pendingMigration = true;
            } else {
              // 已迁移：凭据仅在 [loadSecret] 解密后才在缓存中（否则为空）
              final sec = cache[cfg.id];
              servers.add(cfg.copyWith(
                password: sec?['password'] ?? '',
                accessToken: sec?['accessToken'],
              ));
            }
          }
          if (pendingMigration) {
            final ids = servers.map((s) => s.id).toSet();
            _enqueue(() => _migrate(servers, activeServerId, ids));
          }
          return (servers: servers, activeServerId: activeServerId);
        }
      }
    } catch (_) {
      // 损坏的存储文件：回退空列表
    }
    return (servers: const [], activeServerId: null);
  }

  /// 按需解密单个服务器凭据进内存缓存（[load] 同步读取的来源）。
  /// 已缓存（已知或已显式清空）则直接返回；vault 不可用/解密失败不抛
  /// （保持未缓存，下次调用重试），绝不因此丢配置。
  static Future<void> loadSecret(String id) async {
    final cache = _secretCache.putIfAbsent(filePath, () => {});
    if (cache.containsKey(id)) return; // 已加载 / 已显式清空
    if (!VaultProcess.available) return;
    try {
      final raw = await VaultProcess.get(_dir(), _uidFor(id),
          password: _sessionPassword, recoveryCode: _sessionRecoveryCode);
      if (raw == null || raw == 'null') return;
      final sec = _decodeSecret(raw);
      if (sec != null) cache[id] = sec;
    } on VaultNeedRecoveryException catch (e) {
      _needsRecovery = true;
      stderr.writeln('[vault] 流媒体凭据需恢复码解锁：$e');
    } catch (e) {
      stderr.writeln('[vault] 流媒体凭据解密失败（$id）：$e');
    }
  }

  /// 是否已加载该服务器的凭据（内存中且非空）。
  static bool hasSecret(String id) {
    final sec = _secretCache[filePath]?[id];
    return sec != null && sec.isNotEmpty;
  }

  /// 已加载的凭据（未加载 / 已显式清空返回 null）。
  static Map<String, String>? cachedSecret(String id) {
    final sec = _secretCache[filePath]?[id];
    if (sec == null || sec.isEmpty) return null;
    return Map<String, String>.unmodifiable(sec);
  }

  /// 直接写入/合并单条凭据（如 Jellyfin/Emby 鉴权后回填 accessToken），
  /// 不触碰其它字段（保留既有 password/token）：合并后异步落库。
  static void saveSecret(
    String id, {
    String? password,
    String? accessToken,
  }) {
    final cache = _secretCache.putIfAbsent(filePath, () => {});
    final cur = Map<String, String>.from(cache[id] ?? const {});
    if (password != null && password.isNotEmpty) cur['password'] = password;
    if (accessToken != null) {
      if (accessToken.isEmpty) {
        cur.remove('accessToken');
      } else {
        cur['accessToken'] = accessToken;
      }
    }
    cache[id] = cur;
    if (!VaultProcess.available) return;
    _enqueue(() => _persistSecrets({id}));
  }

  /// 显式清除某服务器凭据（用户在表单清空口令 / 删除服务器前主动清理）：
  /// 标记缓存为「已清空」并异步删除 vault 条目。与 [save] 的
  /// 「未知则跳过」区分——这是调用方明确表达的删除意图。
  static void clearSecret(String id) {
    final cache = _secretCache.putIfAbsent(filePath, () => {});
    cache[id] = const {};
    if (!VaultProcess.available) return;
    _enqueue(() => _persistSecrets(const <String>{}, removedIds: {id}));
  }

  /// 磁盘上当前已存在的服务器 id（区分「新增」与「既有」，避免 metadata-only
  /// 保存误覆盖/漏删既有凭据条目）。
  static Set<String> _persistedIds() {
    try {
      final text = SafeFile.readString(filePath);
      if (text == null) return const {};
      final json = jsonDecode(text);
      if (json is Map && json['servers'] is List) {
        final out = <String>{};
        for (final e in (json['servers'] as List).whereType<Map>()) {
          final id = e['id']?.toString();
          if (id != null && id.isNotEmpty) out.add(id);
        }
        return out;
      }
    } catch (_) {
      // 损坏文件：按无既有条目处理（不误删未知条目）
    }
    return const {};
  }

  /// 保存服务器列表 + 当前激活服务器 id。
  ///
  /// 凭据写穿内存缓存后异步入 vault；配置文件立即剥离凭据落盘。
  /// **只更新「配置随身携带了凭据」的服务器**（用户编辑/新增）——懒加载
  /// 尚未触发的既有服务器保持缓存原状，[_persistSecrets] 跳过，绝不因
  /// metadata-only 保存（改名/排序/连接回填）覆盖或清空 vault 中既有凭据。
  /// 删除经磁盘既有 id 判定（未加载的服务器也能正确删条目）。
  /// vault 完全不可用（二进制缺失）时回写含凭据旧形态并告警——
  /// 不静默丢弃凭据（用户重填成本 > 迁移前明文暴露，且该状态等同迁移前）。
  static void save(List<StreamingServerConfig> servers, String? activeServerId) {
    final cache = _secretCache.putIfAbsent(filePath, () => {});
    final ids = servers.map((s) => s.id).toSet();
    final persistedIds = _persistedIds();
    for (final s in servers) {
      final hasPassword = s.password.isNotEmpty;
      final hasToken = s.accessToken?.isNotEmpty ?? false;
      if (hasPassword || hasToken) {
        // 用户编辑/新增携带凭据：**合并**（保留配置未携带的字段，如 token）
        final cur = Map<String, String>.from(cache[s.id] ?? const {});
        if (hasPassword) cur['password'] = s.password;
        if (hasToken) cur['accessToken'] = s.accessToken!;
        cache[s.id] = cur;
      } else if (!persistedIds.contains(s.id) && !cache.containsKey(s.id)) {
        // 新增且无凭据：显式标记空（无既有条目可覆盖）
        cache[s.id] = const {};
      }
      // 既有且未携带凭据：保持缓存原状（未知留待 loadSecret / 已知则保留）
    }
    // 删除：缓存已知 + 磁盘既有（覆盖「未加载过即被删除」的情形）
    final removedIds = <String>{
      ...cache.keys.where((id) => !ids.contains(id)),
      ...persistedIds.where((id) => !ids.contains(id)),
    };
    for (final id in removedIds) {
      cache.remove(id);
    }
    if (!VaultProcess.available) {
      _writeFile(servers, activeServerId, includeSecrets: true);
      _warnVaultDown();
      return;
    }
    _writeFile(servers, activeServerId, includeSecrets: false);
    _enqueue(() => _persistSecrets(ids, removedIds: removedIds));
  }

  static void _writeFile(
    List<StreamingServerConfig> servers,
    String? activeServerId, {
    required bool includeSecrets,
  }) {
    try {
      SafeFile.writeAtomicString(filePath, const JsonEncoder.withIndent('  ').convert({
        'servers': [
          for (final s in servers)
            if (includeSecrets) s.toJson() else _withoutSecrets(s),
        ],
        'activeServerId': activeServerId,
      }));
    } catch (_) {
      // 持久化失败不阻塞（自用项目，配置丢失可接受）
    }
  }

  static Map<String, dynamic> _withoutSecrets(StreamingServerConfig s) {
    final json = s.toJson()
      ..remove('password')
      ..remove('accessToken');
    return json;
  }

  /// 凭据入 vault（仅缓存中**已知**的条目）；任一步失败返回 false。
  /// [ids] 为当前服务器集合；[removedIds] 为已删除服务器（显式删除）。
  /// 缓存中不存在（未知，懒加载未触发）的 id 一律跳过——绝不写空覆盖。
  /// m1/m2a 模式：须本会话已解锁（[unlockWithPassword] 后 [_sessionPassword]
  /// 非空，或恢复路径持 [_sessionRecoveryCode]）；未解锁时落库失败（返回
  /// false，文件保持原样）。
  static Future<bool> _persistSecrets(
    Set<String> ids, {
    Set<String> removedIds = const {},
  }) async {
    try {
      if (!VaultProcess.available) return false;
      if (!await VaultProcess.isInitialized(_dir())) {
        // 惰性重建（销毁后自动重建）：按默认方案初始化
        if (defaultScheme == 'file') {
          await VaultProcess.initFile(_dir());
        } else {
          await VaultProcess.initCrypto(_dir());
        }
      }
      final cache = _secretCache[filePath] ?? const {};
      for (final id in {...ids, ...removedIds}) {
        if (removedIds.contains(id)) {
          await VaultProcess.delete(_dir(), _uidFor(id),
              password: _sessionPassword, recoveryCode: _sessionRecoveryCode);
          continue;
        }
        if (!cache.containsKey(id)) continue; // 未知（未加载）：跳过，不覆盖
        final sec = cache[id];
        if (sec == null || sec.isEmpty) {
          await VaultProcess.delete(_dir(), _uidFor(id),
              password: _sessionPassword, recoveryCode: _sessionRecoveryCode);
        } else {
          await VaultProcess.set(_dir(), _uidFor(id), jsonEncode(sec),
              password: _sessionPassword, recoveryCode: _sessionRecoveryCode);
        }
      }
      return true;
    } on VaultNeedRecoveryException catch (e) {
      // m2a device.key 缺失：可恢复状态，标记待恢复（UI 弹恢复流）
      _needsRecovery = true;
      stderr.writeln('[vault] 流媒体凭据需恢复码解锁：$e');
      return false;
    } catch (e) {
      _warnVaultDown();
      stderr.writeln('[vault] 流媒体凭据落库失败：$e');
      return false;
    }
  }

  /// 旧明文迁移：凭据入 vault 成功后才覆写文件为无凭据形态；
  /// 失败保留原文件（下次启动重试），防止凭据丢失。
  static Future<bool> _migrate(
    List<StreamingServerConfig> servers,
    String? activeServerId,
    Set<String> ids,
  ) async {
    final ok = await _persistSecrets(ids);
    if (!ok) return false;
    _writeFile(servers, activeServerId, includeSecrets: false);
    return true;
  }
}
