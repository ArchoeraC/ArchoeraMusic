// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import '../apis/runtime.dart';
import '../services/security/data_destroyer.dart' show shredFile;
import '../services/security/vault_kdf.dart';
import '../services/security/vault_process.dart';
import 'data_dir.dart';
import '../utils/safe_file.dart';

/// vault 会话存储：凭据加密落盘（`credentials.vault`；crypto 单因子存
/// OS 安全存储/文件密钥库，或 slots 槽位表封装主密钥），替代原明文
/// `netease_session.json`。
///
/// 接口约束：[SessionStore] 为同步，vault 进程 I/O 为异步 → 写穿缓存：
///   内存缓存即时可见（get/save/clear 同步返回），vault 持久化经串行
///   队列异步执行（防乱序覆盖）。启动时 [initialize] 从 vault 加载并
///   迁移旧明文文件（main 中 await 后再 runApp）。
///
/// 降级语义（不静默写明文）：vault 不可用（二进制缺失 / OS 安全存储
/// 缺失 / 数据损坏）→ 仅内存保留（登录态重启即失），[main] 打印警告。
class VaultSessionStore implements SessionStore {
  static const List<String> knownPlatforms = [
    'netease',
    'kugou',
    'qqmusic',
  ];
  static const String _uidPrefix = 'session:';

  final Map<String, Map<String, String>> _cache = {};
  Future<void> _queue = Future.value();
  bool _vaultOk = false;
  String? _mode;
  bool _needsRecovery = false;

  /// 份额不配对（v4 指纹校验 backend 不符 / 份额缺失 / GCM 认证失败）：
  /// vault 无法解密且数据不可恢复——UI 应引导「销毁重建」而非反复重试。
  bool _shareBroken = false;

  /// m1/m2a 解锁口令（内存持有，仅用于 serve 握手；绝不持久化/写盘；
  /// 应用重启后需重新输入）。
  String? _sessionPassword;

  /// m2a 恢复码（device.key 缺失时经恢复槽解锁；内存持有，仅用于握手）。
  String? _sessionRecoveryCode;

  final String _dataDir;

  /// 未初始化时的默认加密方案（`crypto`=LEGACY 单因子推荐 / `file`=文件密钥）。
  /// 已初始化的库按自身模式解锁，不受本值影响；惰性重建时按本值选择。
  final String defaultScheme;

  VaultSessionStore({String? dataDir, this.defaultScheme = 'crypto'})
    : _dataDir = dataDir ?? resolveDataDir();

  /// vault 当前可用（加载/持久化最近一次成功）。
  bool get vaultAvailable => _vaultOk;

  /// 未解锁 / 不可用（含份额不配对、待恢复）→ 消费方不得把空会话当作「未登录」缓存。
  @override
  bool get isLocked => !_vaultOk;

  /// vault 模式：`crypto` | `m1` | `m2a` | `m2b`；未初始化/不可用返回 null。
  String? get mode => _mode;

  /// m1/m2a 模式且本次会话尚未解锁：需 [unlockWithPassword] 输入口令。
  bool get needsPassword => (_mode == 'm1' || _mode == 'm2a') && !_vaultOk;

  /// 本次会话的解锁口令（m1/m2a；内存态；未解锁返回 null）。仅用于 vault
  /// 握手，绝不持久化；UI 层调用方使用后即弃。
  String? get sessionPassword => _sessionPassword;

  /// m1/m2a 口令解锁（每次会话启动后调用）：用口令解锁并加载全部会话；
  /// 口令仅内存持有（[unlockWithPassword] 后本会话 vault 可用）。
  /// 成功后 [needsPassword] 复位。口令用后即弃不缓存（与握手同语义，
  /// 但本会话后续持久化仍须传入——见 [_persist] 的 `_sessionPassword`）。
  Future<bool> unlockWithPassword(String password) async {
    if (_mode != 'm1' && _mode != 'm2a') return false;
    try {
      await _loadFromVault(password: password);
      _sessionPassword = password;
      _sessionRecoveryCode = null;
      _vaultOk = true;
      return true;
    } on VaultNeedRecoveryException catch (e) {
      // m2a device.key 缺失：口令路径不可解锁，转恢复码流（非爆破向量）。
      _vaultOk = false;
      _sessionPassword = null;
      _needsRecovery = true;
      stderr.writeln('[vault] 设备因子缺失，需恢复码解锁：$e');
      return false;
    } on VaultException catch (e) {
      // 错误口令/锁定：复位解锁态——vault 仍不可用、needsPassword 保持 true，
      // 用户可重试；旧会话口令作废（绝不带错误口令继续持久化）。
      _vaultOk = false;
      _sessionPassword = null;
      stderr.writeln('[vault] 口令解锁失败：$e');
      return false;
    }
  }

  /// 设备变更/熵损坏：vault 为 m2a 且 device.key 缺失（serve `err NEED_RECOVERY`）
  /// → 需「恢复码」解锁。与锁定退避不同：恢复场景非爆破尝试，不计退避。
  bool get needsRecovery => _needsRecovery;

  /// 份额不配对（[VaultShareBackendMismatchException] / [VaultShareMissingException] /
  /// [VaultShareMismatchException]）：vault 无法解密且数据不可恢复——
  /// UI 应引导「销毁重建」（安全设置页显著提示），而非反复重试。
  bool get shareBroken => _shareBroken;

  /// 重键 Argon2id 强度（m1/m2a）：以 [preset] 对应的 m/t/p 重新封装口令槽，
  /// **主密钥 K 与全部会话条目保持不变**（无数据丢失）。
  /// [password] 为当前解锁口令（默认取本会话已解锁口令 [_sessionPassword]）；
  /// m2a 须 device.key 可用，否则 vault 返回 `NEED_RECOVERY`（经 [VaultException] 上抛）。
  /// 成功后由调用方持久化偏好（本方法不触碰 prefs）。
  Future<void> setKdfPreset(String preset, {String? password}) async {
    final p = vaultKdfPresetById(preset);
    await VaultProcess.setKdf(
      _dataDir,
      m: p.mKiB,
      t: p.t,
      p: p.p,
      password: password ?? _sessionPassword,
    );
  }

  /// 恢复解锁（m2a device.key 缺失）：用恢复码解锁并重新加载全部会话。
  /// 成功后 [needsRecovery] 复位；恢复码仅内存持有（后续持久化随握手携带），
  /// 用后即弃不缓存。返回是否成功。
  Future<bool> recover(String recoveryCode) async {
    if (!VaultProcess.available) return false;
    try {
      final cache = <String, Map<String, String>>{};
      for (final platform in knownPlatforms) {
        final raw = await VaultProcess.get(
          _dataDir,
          _uidFor(platform),
          recoveryCode: recoveryCode,
        );
        if (raw == null) continue;
        final decoded = jsonDecode(utf8.decode(base64Decode(raw)));
        if (decoded is Map<String, dynamic>) {
          cache[platform] = decoded.map((k, v) => MapEntry(k, v.toString()));
        }
      }
      _cache
        ..clear()
        ..addAll(cache);
      _needsRecovery = false;
      _sessionRecoveryCode = recoveryCode;
      _sessionPassword = null;
      _vaultOk = true;
      return true;
    } on VaultException catch (e) {
      // 恢复码错误（触发锁定退避）/其他拒绝：恢复失败，保持 needsRecovery
      stderr.writeln('[vault] 恢复码解锁失败：$e');
      return false;
    }
  }

  /// 等待持久化队列排空（登出/退出前落盘确认；测试断言用）。
  Future<void> flush() => _queue;

  String _legacyPath() => '$_dataDir/netease_session.json';

  /// 启动初始化：迁移旧明文文件 → 从 vault 加载全部平台会话。
  /// 任何失败均不阻断启动（内存降级），调用方负责提示。
  Future<void> initialize() async {
    _queue = _queue.then((_) => _initialize());
    await _queue;
  }

  Future<void> _initialize() async {
    if (!VaultProcess.available) return; // 缺二进制：纯内存
    try {
      // 首次运行（新数据目录）惰性初始化 vault；已初始化则跳过。
      // 默认 crypto（LEGACY 单因子，推荐稳定）；defaultScheme='file' 走文件
      // 密钥模式（免 OS 钥匙串）——设置页/首次对话框选择后冷切重启生效。
      // 历史 'vault'（2-of-2，已移除）回落 crypto。
      if (!await VaultProcess.isInitialized(_dataDir)) {
        // 惰性初始化**仅限免密方案**：m1/m2a/m2b 需要用户因子（口令/device.key/恢复码），
        // 静默 init 成 crypto 是安全降级且会造成 pref/容器不一致 → 留给 UI 初始化门。
        if (!VaultProcess.isPasswordlessScheme(defaultScheme)) {
          stderr.writeln('[vault] 库缺失且方案 $defaultScheme 需要用户因子：等待显式初始化');
          return;
        }
        if (defaultScheme == 'file') {
          await VaultProcess.initFile(_dataDir);
        } else {
          await VaultProcess.initCrypto(_dataDir);
        }
        _mode = 'crypto'; // 模式恒为 crypto（'C'）；file 只是后端差异（backend=file）
      } else {
        _mode = await VaultProcess.mode(_dataDir);
      }
      if (_mode == 'm1' || _mode == 'm2a') {
        // m1/m2a：本会话未解锁 → needsPassword=true（UI 引导输入口令）。
        // 不尝试无口令加载（必失败），也不静默降级——登录态仅内存保留。
        _vaultOk = false;
        _cache.clear();
        return;
      }
      await _loadFromVault();
      _vaultOk = true;
      _shareBroken = false; // 解锁成功（销毁重建或后端恢复）→ 复位不配对标记
    } on VaultNeedRecoveryException catch (e) {
      // m2a device.key 缺失：fail-closed 不加载，标记待恢复。
      // 与普通不可用不同：这是「可恢复」状态，UI 应弹恢复流而非静默降级。
      _needsRecovery = true;
      _vaultOk = false;
      _cache.clear();
      stderr.writeln('[vault] 设备因子缺失，需恢复码解锁：$e');
    } on VaultShareMismatchException catch (e) {
      _markShareBroken(e);
    } on VaultShareBackendMismatchException catch (e) {
      _markShareBroken(e);
    } on VaultShareMissingException catch (e) {
      _markShareBroken(e);
    } catch (e) {
      // 缺 OS 安全存储 / 数据损坏等：内存降级，不静默写明文
      _vaultOk = false;
      _cache.clear();
      stderr.writeln('[vault] 凭据保险库不可用，登录态将不持久化：$e');
    }
  }

  /// 份额不配对（backend 指纹不符 / 份额缺失 / GCM 认证失败）：
  /// vault 无法解密且数据不可恢复——标记 [shareBroken] 供 UI 引导销毁重建，
  /// 不静默降级（不写明文、不重试），不触发恢复流（无口令封装可解）。
  void _markShareBroken(VaultException e) {
    _shareBroken = true;
    _vaultOk = false;
    _cache.clear();
    stderr.writeln('[vault] 凭据保险库份额不配对，需销毁重建：$e');
  }

  /// 从 vault 加载全部平台会话（m1/m2a 须传 [password] 或 [recoveryCode]；
  /// 迁移旧明文）。
  Future<void> _loadFromVault({String? password, String? recoveryCode}) async {
    await _migrateLegacy(password: password, recoveryCode: recoveryCode);
    for (final platform in knownPlatforms) {
      final raw = await VaultProcess.get(
        _dataDir,
        _uidFor(platform),
        password: password,
        recoveryCode: recoveryCode,
      );
      if (raw == null) continue;
      final decoded = jsonDecode(utf8.decode(base64Decode(raw)));
      if (decoded is Map<String, dynamic>) {
        _cache[platform] = decoded.map((k, v) => MapEntry(k, v.toString()));
      }
    }
  }

  /// 旧明文 `netease_session.json` 一次性迁移进 vault 后覆盖删除。
  /// 迁移失败保留原文件（安全设置页「清除会话」仍可兜底删除）。
  Future<void> _migrateLegacy({String? password, String? recoveryCode}) async {
    final legacy = File(_legacyPath());
    final legacyText = SafeFile.readString(legacy.path); // 非普通文件 → 视为不存在
    if (legacyText == null) return;
    try {
      final json = jsonDecode(legacyText);
      if (json is Map<String, dynamic>) {
        for (final e in json.entries) {
          final v = e.value;
          if (v is Map<String, dynamic>) {
            final cookies = v.map((k, val) => MapEntry(k, val.toString()));
            if (cookies.isNotEmpty) {
              await VaultProcess.set(
                _dataDir,
                _uidFor(e.key),
                jsonEncode(cookies),
                password: password,
                recoveryCode: recoveryCode,
              );
              _cache[e.key] = cookies;
            }
          }
        }
      }
      // 迁移成功：覆盖删除旧明文（原 netease_session.json 语义仍由
      // data_destroyer 提供，若失败保留文件供下次重试）
      final r = shredFile(_legacyPath());
      if (r.existed && !r.shredded) {
        stderr.writeln('[vault] 旧明文会话文件删除失败，请手动清理：${r.path}');
      }
    } catch (e) {
      stderr.writeln('[vault] 旧明文会话迁移失败（保留原文件）：$e');
    }
  }

  static String _uidFor(String platform) => '$_uidPrefix$platform';

  // ── SessionStore（同步）──────────────────────────────────────────

  @override
  Map<String, String> get(String platform) => _cache[platform] ?? {};

  @override
  void save(String platform, Map<String, String> cookies) {
    _cache[platform] = {...cookies};
    _enqueue(() => _persist(platform));
  }

  @override
  void clear(String platform) {
    _cache[platform] = {};
    _enqueue(() => _persist(platform));
  }

  // ── 持久化（异步串行）────────────────────────────────────────────

  void _enqueue(Future<void> Function() op) {
    _queue = _queue.then((_) => op()).catchError((Object e) {
      stderr.writeln('[vault] 持久化失败：$e');
    });
  }

  /// 将平台会话刷入 vault。vault 未初始化时惰性 init（销毁后重新登录
  /// 自动重建）；不可用时降级内存（登录态重启即失）。
  /// m1/m2a 模式：须本会话已解锁（[unlockWithPassword] 后 [_sessionPassword]
  /// 非空，或恢复路径持 [_sessionRecoveryCode]）；未解锁时仅内存保留。
  Future<void> _persist(String platform) async {
    try {
      if (!VaultProcess.available) {
        _vaultOk = false;
        return;
      }
      // **锁定态（m1/m2a 本会话未解锁）：不尝试写入、不标失败、不刷警告**。
      // 启动时库必然是锁着的（m2a 正常态），此处"必然失败"会被误读为故障，
      // 并把 _vaultOk 污染为 false（2026-10-14 实录）。登录态仅内存保留，
      // 解锁后由加载路径恢复权威值（load 为准，不把锁定期的临时值写回去）。
      if ((_mode == 'm1' || _mode == 'm2a') &&
          _sessionPassword == null &&
          _sessionRecoveryCode == null) {
        return;
      }
      if (!await VaultProcess.isInitialized(_dataDir)) {
        // 库不存在：**仅免密方案**可惰性重建；m1/m2a/m2b 需要用户因子，
        // 静默建 crypto 是安全降级且会造成 pref/容器不一致（同 _initialize 门控）。
        if (!VaultProcess.isPasswordlessScheme(defaultScheme)) return;
        if (defaultScheme == 'file') {
          await VaultProcess.initFile(_dataDir);
        } else {
          await VaultProcess.initCrypto(_dataDir);
        }
      }
      _vaultOk = true;
      _shareBroken = false; // 持久化成功（销毁重建后自动重建）→ 复位不配对标记
      final cookies = _cache[platform];
      if (cookies == null || cookies.isEmpty) {
        await VaultProcess.delete(
          _dataDir,
          _uidFor(platform),
          password: _sessionPassword,
          recoveryCode: _sessionRecoveryCode,
        );
      } else {
        await VaultProcess.set(
          _dataDir,
          _uidFor(platform),
          jsonEncode(cookies),
          password: _sessionPassword,
          recoveryCode: _sessionRecoveryCode,
        );
      }
    } on VaultNeedRecoveryException catch (e) {
      // m2a device.key 缺失：标记待恢复（登录态仅内存保留，等待恢复流解锁）
      _needsRecovery = true;
      _vaultOk = false;
      stderr.writeln('[vault] 设备因子缺失，需恢复码解锁：$e');
    } on VaultShareMismatchException catch (e) {
      _markShareBroken(e);
    } on VaultShareBackendMismatchException catch (e) {
      _markShareBroken(e);
    } on VaultShareMissingException catch (e) {
      _markShareBroken(e);
    } catch (e) {
      _vaultOk = false;
      stderr.writeln('[vault] 持久化失败（登录态仅内存保留）：$e');
    }
  }
}
