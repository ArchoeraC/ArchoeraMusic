import 'dart:convert';
import 'dart:io';

import '../apis/runtime.dart';
import '../services/security/data_destroyer.dart' show shredFile;
import '../services/security/vault_process.dart';
import 'data_dir.dart';

/// vault 会话存储：凭据加密落盘（`credentials.vault` + OS 安全存储份额，
/// 2-of-2 协同解密），替代原明文 `netease_session.json`。
///
/// 接口约束：[SessionStore] 为同步，vault 进程 I/O 为异步 → 写穿缓存：
///   内存缓存即时可见（get/save/clear 同步返回），vault 持久化经串行
///   队列异步执行（防乱序覆盖）。启动时 [initialize] 从 vault 加载并
///   迁移旧明文文件（main 中 await 后再 runApp）。
///
/// 降级语义（不静默写明文）：vault 不可用（二进制缺失 / OS 安全存储
/// 缺失 / 数据损坏）→ 仅内存保留（登录态重启即失），[main] 打印警告。
class VaultSessionStore implements SessionStore {
  static const List<String> knownPlatforms = ['kugou', 'netease'];
  static const String _uidPrefix = 'session:';

  final Map<String, Map<String, String>> _cache = {};
  Future<void> _queue = Future.value();
  bool _vaultOk = false;
  String? _mode;
  bool _needsRecovery = false;

  /// 份额不配对（v4 指纹校验 backend 不符 / 份额缺失 / GCM 认证失败）：
  /// vault 无法解密且数据不可恢复——UI 应引导「销毁重建」而非反复重试。
  bool _shareBroken = false;

  /// v2 口令模式：本次会话的解锁口令（内存持有，仅用于 serve 握手；
  /// 绝不持久化/写盘；应用重启后需重新输入）。
  String? _sessionPassword;

  final String _dataDir;

  /// 未初始化时的默认加密方案（`crypto`=LEGACY 单因子推荐 / `vault`=2-of-2 实验性）。
  /// 已初始化的库按自身模式解锁，不受本值影响；惰性重建时按本值选择。
  final String defaultScheme;

  VaultSessionStore({String? dataDir, this.defaultScheme = 'crypto'})
      : _dataDir = dataDir ?? resolveDataDir();

  /// vault 当前可用（加载/持久化最近一次成功）。
  bool get vaultAvailable => _vaultOk;

  /// vault 份额锚定模式：`os` | `password` | `multiseal`；未初始化/不可用返回 null。
  String? get mode => _mode;

  /// v2 口令模式且本次会话尚未解锁：需 [unlockWithPassword] 输入口令。
  /// 与 [needsRecovery]（v3 设备变更）不同：v2 每次会话都需口令。
  bool get needsPassword => _mode == 'password' && !_vaultOk;

  /// v2 口令模式本会话已解锁（[unlockWithPassword] 成功）：会话口令内存持有，
  /// 供设置页升级设备绑定（[VaultProcess.upgradeDevice] 握手）等需要口令的操作。
  bool get isV2Unlocked => _mode == 'password' && _vaultOk;

  /// 本次会话的 v2 解锁口令（内存态；未解锁返回 null）。仅用于 vault 握手，
  /// 绝不持久化；UI 层调用方使用后即弃。
  String? get sessionPassword => _sessionPassword;

  /// v2 口令解锁（每次会话启动后调用）：用口令解锁并加载全部会话；
  /// 口令仅内存持有（[unlockWithPassword] 后本会话 vault 可用）。
  /// 成功后 [needsPassword] 复位。口令用后即弃不缓存（与握手同语义，
  /// 但本会话后续持久化仍须传入——见 [_persist] 的 `_sessionPassword`）。
  Future<bool> unlockWithPassword(String password) async {
    if (_mode != 'password') return false;
    try {
      await _loadFromVault(password: password);
      _sessionPassword = password;
      _vaultOk = true;
      return true;
    } on VaultException catch (e) {
      // 错误口令/锁定：复位解锁态——vault 仍不可用、needsPassword 保持 true，
      // 用户可重试；旧会话口令作废（绝不带错误口令继续持久化）。
      _vaultOk = false;
      _sessionPassword = null;
      stderr.writeln('[vault] 口令解锁失败：$e');
      return false;
    }
  }

  /// 是否为设备绑定多封装（v3，BitLocker 式：本机免密 + 换机恢复口令）。
  bool get isDeviceBound => _mode == 'multiseal';

  /// 设备变更/熵损坏：vault 有口令封装但熵路径解锁失败（serve `err NEED_RECOVERY`）
  /// → 需「恢复口令」解锁。与锁定退避不同：恢复场景非爆破尝试，不计退避。
  bool get needsRecovery => _needsRecovery;

  /// 份额不配对（[VaultShareBackendMismatchException] / [VaultShareMissingException] /
  /// [VaultShareMismatchException]）：vault 无法解密且数据不可恢复——
  /// UI 应引导「销毁重建」（安全设置页显著提示），而非反复重试。
  bool get shareBroken => _shareBroken;

  /// v1 ↔ v2 份额迁移（三档切换条：系统保护 ↔ 口令保护）：
  /// 主密钥 K 不变、既有条目原样沿用（无需重加密），仅切换授权份额 S
  /// 的锚定方式（OS 安全存储 ↔ Argon2id 口令）。
  ///   [target]='password'（v1 → v2）：[newPassword] 为新会话口令（必填）；
  ///   [target]='os'（v2 → v1）：须本会话已解锁（持 [_sessionPassword]）。
  /// 成功后更新本会话状态：
  ///   password：新口令即会话口令，本会话保持解锁（无需重新输入）；
  ///   os：清空会话口令（OS 份额接管，免密）。
  /// 失败抛 [VaultException]（UI toast）且状态不变。v3 多封装不可经此切换
  /// （须走设备绑定关闭入口回落 v2）。
  Future<void> switchMode(String target, {String? newPassword}) async {
    if (_mode == 'multiseal' || target == 'multiseal') {
      throw VaultException(
          '设备绑定（v3）不可经 switch-mode 互切，请使用设备绑定管理入口');
    }
    if (target == 'password' &&
        (newPassword == null || newPassword.isEmpty)) {
      throw VaultException('切换到口令保护须设置新口令');
    }
    try {
      await VaultProcess.switchMode(_dataDir, target,
          newPassword: newPassword, password: _sessionPassword);
      _mode = target;
      _needsRecovery = false;
      _vaultOk = true;
      _sessionPassword = target == 'os' ? null : newPassword;
    } on VaultException {
      rethrow; // 失败保持原状态（含未解锁时 v2→v1 握手拒绝）
    }
  }

  /// 设备绑定开关（v3 启/闭）后的模式同步：vault 文件已由 VaultProcess
  /// 变更，本 store 同步内存态，避免 [needsPassword]/[isDeviceBound] 与
  /// 磁盘实际模式脱节。[sessionPassword] 为切换后的新会话口令
  /// （v3 关闭回落 v2 = 恢复口令）；OS/多封装免密传 null。
  void syncMode(String mode, {String? sessionPassword}) {
    _mode = mode;
    _sessionPassword = sessionPassword;
    _needsRecovery = false;
    _vaultOk = true;
  }

  /// 恢复解锁（设备变更/熵损坏）：用恢复口令解锁并重新加载全部会话。
  /// 成功后 [needsRecovery] 复位；此后可经 [VaultProcess.rebind] 重绑定
  /// 当前设备，恢复本机免密。口令用后即弃不缓存（与握手同语义）。
  Future<bool> recover(String recoveryPassword) async {
    if (!VaultProcess.available) return false;
    try {
      final cache = <String, Map<String, String>>{};
      for (final platform in knownPlatforms) {
        final raw = await VaultProcess.get(_dataDir, _uidFor(platform),
            password: recoveryPassword);
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
      _vaultOk = true;
      return true;
    } on VaultException catch (e) {
      // 口令错误（触发锁定退避）/其他拒绝：恢复失败，保持 needsRecovery
      stderr.writeln('[vault] 恢复口令解锁失败：$e');
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
      // 默认 crypto（LEGACY 单因子，推荐稳定）；defaultScheme='vault'
      // 时走 2-of-2（实验性）；'file' 走文件密钥模式（LEGACY 兼容，
      // 免 OS 钥匙串）——设置页/首次对话框选择后冷切重启生效。
      if (!await VaultProcess.isInitialized(_dataDir)) {
        if (defaultScheme == 'vault') {
          await VaultProcess.init(_dataDir);
          _mode = 'os';
        } else if (defaultScheme == 'file') {
          await VaultProcess.initFile(_dataDir);
          _mode = 'crypto';
        } else {
          await VaultProcess.initCrypto(_dataDir);
          _mode = 'crypto';
        }
      } else {
        _mode = await VaultProcess.mode(_dataDir);
      }
      if (_mode == 'password') {
        // v2 口令模式：本会话未解锁 → needsPassword=true（UI 引导输入口令）。
        // 不尝试无口令加载（必失败），也不静默降级——登录态仅内存保留。
        _vaultOk = false;
        _cache.clear();
        return;
      }
      await _loadFromVault();
      _vaultOk = true;
      _shareBroken = false; // 解锁成功（销毁重建或后端恢复）→ 复位不配对标记
    } on VaultNeedRecoveryException catch (e) {
      // 设备变更/熵损坏（v3 有口令封装）：fail-closed 不加载，标记待恢复。
      // 与普通不可用不同：这是「可恢复」状态，UI 应弹恢复流而非静默降级。
      _needsRecovery = true;
      _vaultOk = false;
      _cache.clear();
      stderr.writeln('[vault] 设备变更/熵损坏，需恢复口令解锁：$e');
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

  /// 从 vault 加载全部平台会话（口令模式须传 [password]；迁移旧明文）。
  Future<void> _loadFromVault({String? password}) async {
    await _migrateLegacy(password: password);
    for (final platform in knownPlatforms) {
      final raw = await VaultProcess.get(_dataDir, _uidFor(platform),
          password: password);
      if (raw == null) continue;
      final decoded = jsonDecode(utf8.decode(base64Decode(raw)));
      if (decoded is Map<String, dynamic>) {
        _cache[platform] = decoded.map((k, v) => MapEntry(k, v.toString()));
      }
    }
  }

  /// 旧明文 `netease_session.json` 一次性迁移进 vault 后覆盖删除。
  /// 迁移失败保留原文件（安全设置页「清除会话」仍可兜底删除）。
  Future<void> _migrateLegacy({String? password}) async {
    final legacy = File(_legacyPath());
    if (!legacy.existsSync()) return;
    try {
      final json = jsonDecode(legacy.readAsStringSync());
      if (json is Map<String, dynamic>) {
        for (final e in json.entries) {
          final v = e.value;
          if (v is Map<String, dynamic>) {
            final cookies = v.map((k, val) => MapEntry(k, val.toString()));
            if (cookies.isNotEmpty) {
              await VaultProcess.set(_dataDir, _uidFor(e.key), jsonEncode(cookies),
                  password: password);
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
  /// v2 口令模式：须本会话已解锁（[unlockWithPassword] 后 [_sessionPassword]
  /// 非空）；未解锁时仅内存保留（持久化跳过，UI 引导解锁）。
  Future<void> _persist(String platform) async {
    try {
      if (!VaultProcess.available) {
        _vaultOk = false;
        return;
      }
      if (!await VaultProcess.isInitialized(_dataDir)) {
        // 惰性重建（销毁后重新登录自动重建）：按默认方案初始化
        if (defaultScheme == 'vault') {
          await VaultProcess.init(_dataDir);
        } else if (defaultScheme == 'file') {
          await VaultProcess.initFile(_dataDir);
        } else {
          await VaultProcess.initCrypto(_dataDir);
        }
      }
      _vaultOk = true;
      _shareBroken = false; // 持久化成功（销毁重建后自动重建）→ 复位不配对标记
      final cookies = _cache[platform];
      if (cookies == null || cookies.isEmpty) {
        await VaultProcess.delete(_dataDir, _uidFor(platform),
            password: _sessionPassword);
      } else {
        await VaultProcess.set(_dataDir, _uidFor(platform), jsonEncode(cookies),
            password: _sessionPassword);
      }
    } on VaultNeedRecoveryException catch (e) {
      // 设备变更/熵损坏：标记待恢复（登录态仅内存保留，等待恢复流解锁）
      _needsRecovery = true;
      _vaultOk = false;
      stderr.writeln('[vault] 设备变更/熵损坏，需恢复口令解锁：$e');
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
