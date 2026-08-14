import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

/// 凭据保险库进程（`archoera-vault` NativeAOT 可执行）封装。
///
/// 会话模式（credential-vault-plan §3.8）：每次操作 spawn `serve` 会话——
/// 血缘校验 → 握手（H/C 经 stdin，应答含锚点 T + HMAC）→ 命令 → `quit` 即退。
/// 崩溃联动（§3.7）：会话非预期退出（信号/挂起/EOF）→ 写 `crash` 标记并
/// 连带终止主进程（fail-closed）；正常结束写 `ok`，主动报错写 `fail`。
/// 下次启动经 [consumeCrashMarker] 读取显著警告（可跳转重置）。
///
/// 安全要点：
/// - 锚点 T（`$dataDir/vault.auth`）由 vault 首会话生成返回并本地保存；
///   后续会话校验一致——「仍是同一把 K 的 vault」（文件被替换 → 拒绝服务）；
/// - **握手版本指纹**：握手应答携带构建标记（`BuildInfo.Marker`），默认路径
///   解析的二进制必须为 PROD（[versionFatal] 校验）；测试/被替换二进制
///   （TEST 标记或无标记）→ 删除副本 + 拒绝解密 + [versionFatal]（仅允许退出）；
/// - 密文负载（[set]）经 stdin 第二行，绝不落 argv；
/// - 测试豁免：`ARCHOERA_VAULT_NO_ABORT=1` 时非预期退出只写标记不 abort
///   （CI/测试专用，生产绝不设置）。
class VaultProcess {
  VaultProcess._();

  static const String envBin = 'ARCHOERA_VAULT_BIN';
  static const String envParentOk = 'ARCHOERA_VAULT_PARENT_OK';
  static const String envNoAbort = 'ARCHOERA_VAULT_NO_ABORT';

  static const String markerOk = 'ok';
  static const String markerCrash = 'crash';
  static const String markerFail = 'fail';

  static const Duration handshakeTimeout = Duration(seconds: 10);
  static const Duration _cmdTimeout = Duration(seconds: 15);

  /// 候选相对路径（bundle `native/` 平铺优先，dev 产物目录兜底）。
  static const List<String> _candidates = [
    'native',
    'core/vault/build',
    'vault/build',
  ];

  static String? _binary;

  /// 当前二进制是否来自显式 `ARCHOERA_VAULT_BIN`（测试/CI 信任边界）。
  /// 默认路径解析的二进制须通过 [VaultProcess.versionFatal] 校验（PROD 标记）。
  static bool _binaryFromEnv = false;

  /// 版本异常 fatal 状态（[VaultVersionException] 触发时置位）：
  /// 非空 = vault 二进制版本/标记异常，副本已删除、解密被拒——
  /// UI 应显示「仅允许用户退出」页（见 VaultVersionGate）。
  /// 值为结构化原因枚举，UI 按枚举映射 l10n 文案（不在 service 层硬编码展示文案）。
  static final ValueNotifier<VaultFatalReason?> versionFatal =
      ValueNotifier<VaultFatalReason?>(null);

  /// vault 二进制绝对路径（惰性解析；未命中抛 [VaultException]）。
  static String get binary => _binary ??= _resolveBinary();

  /// vault 二进制是否可用（未构建/未随包分发/版本异常被删时为 false）。
  static bool get available {
    try {
      binary;
      return true;
    } catch (_) {
      return false;
    }
  }

  static String get _exeName =>
      Platform.isWindows ? 'archoera-vault.exe' : 'archoera-vault';

  static String _resolveBinary() {
    final env = Platform.environment[envBin];
    if (env != null && env.isNotEmpty) {
      // 显式 ARCHOERA_VAULT_BIN（测试/CI/高级用户）：信任该二进制，不做
      // 生产标记校验——设置进程环境本身即需系统权限，生产路径绝不设置；
      _binaryFromEnv = true;
      if (File(env).existsSync()) return File(env).absolute.path;
      final inDir = File('$env/$_exeName');
      if (inDir.existsSync()) return inDir.absolute.path;
    }
    _binaryFromEnv = false;
    String? found;
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 8 && found == null; i++) {
      for (final rel in _candidates) {
        final cand = File('${dir.path}/$rel/$_exeName');
        if (cand.existsSync()) {
          found = cand.absolute.path;
          break;
        }
      }
      dir = dir.parent;
    }
    found ??= () {
      for (final rel in _candidates) {
        final cand = File('${Directory.current.path}/$rel/$_exeName');
        if (cand.existsSync()) return cand.absolute.path;
      }
      return null;
    }();
    if (found == null) {
      throw VaultException('未找到 $_exeName（bundle/native 或 core/vault/build）');
    }
    // 默认路径解析到官方产物后才允许加载
    _verifyProduction(found);
    return found;
  }

  /// 生产标记校验（防「测试/被替换二进制混入发布包」攻击，fail-closed）：
  /// 默认路径解析到的 vault 必须是官方生产构建（`--version` 输出 PROD 标记）。
  /// 测试二进制（TEST 标记）或任何非官方产物 → 删除副本 + 拒绝服务 +
  /// [versionFatal]（UI 全屏警告仅允许退出）——即使攻击者把预编译的测试
  /// 二进制（含明文存储后门）替换进 bundle，应用也不会加载它。
  /// 显式 `ARCHOERA_VAULT_BIN` 不校验（显式信任边界，仅测试/CI 使用）。
  static void _verifyProduction(String path) {
    if (_verifiedBinary == path) return;
    final r = Process.runSync(path, ['--version']);
    if (r.exitCode != 0 || !((r.stdout as String).contains(_prodMarker))) {
      // fail-closed：删除被替换副本 + 拒绝解密 + versionFatal（UI 全屏仅退出）
      _failVersion(
        VaultFatalReason.binaryReplaced,
        log: 'vault binary verification failed at $path: '
            'not an official production build (exit=${r.exitCode})',
        deletePath: path,
      );
      throw VaultVersionException(
        'vault 二进制校验失败：非官方生产产物（可能被替换或损坏），'
        '本地凭据可能已暴露。已删除异常副本并拒绝解密，请重新安装应用。',
      );
    }
    _verifiedBinary = path;
  }

  static String? _verifiedBinary;
  static const String _prodMarker = 'ARCHOERA-VAULT-PROD';

  // ── 生命周期（单命令，不涉凭据读取）────────────────────────────────

  /// 初始化 vault（2-of-2 拆分），返回并保存会话锚点 T（`vault.auth`）。
  static Future<String> init(String dataDir) async {
    final r = Process.runSync(binary, ['init', dataDir]);
    final payload = _parseSync(r.exitCode, r.stdout as String, r.stderr as String);
    if (payload.isNotEmpty) {
      try {
        await File(_authFile(dataDir)).writeAsString(payload);
      } catch (_) {
        // 锚点保存失败不阻断初始化（后续会话将重新补建）
      }
    }
    return payload;
  }

  /// 初始化 vault（LEGACY：crypto 传统单因子，推荐）——主密钥 K 整体存
  /// OS 安全存储（DPAPI/Keychain/libsecret），vault 文件不含密钥材料。
  /// 无份额配对、无口令、无设备熵，稳定性高于 2-of-2（不存在份额丢失
  /// 导致的凭据整体丢失）；安全性降为单点（OS 钥匙串被攻破 = 凭据全泄露）。
  /// 返回并保存会话锚点 T（`vault.auth`）。
  static Future<String> initCrypto(String dataDir) async {
    final r = Process.runSync(binary, ['init-crypto', dataDir]);
    final payload = _parseSync(r.exitCode, r.stdout as String, r.stderr as String);
    if (payload.isNotEmpty) {
      try {
        await File(_authFile(dataDir)).writeAsString(payload);
      } catch (_) {
        // 锚点保存失败不阻断初始化（后续会话将重新补建）
      }
    }
    return payload;
  }

  /// 初始化 vault（文件密钥模式，LEGACY 兼容）：主密钥 K 整体落盘
  /// `$dataDir/secret.key`（0600 原子写；可被 `ARCHOERA_VAULT_SECRET_KEY`
  /// hex64 env 覆盖，env 优先不持久化）——免 OS 钥匙串，供无 Secret
  /// Service 的 headless Linux / Docker 使用（经典的服务端加密形态）。
  /// **本地文件单点：密钥文件泄露 = 凭据全泄露（弱于 OS 存储），
  /// 选用即显式接受该降级。** 复用 crypto 单因子全部配套（握手/崩溃联动/
  /// 目录隔离/可销毁）。返回并保存会话锚点 T（`vault.auth`）。
  static Future<String> initFile(String dataDir) async {
    final r = Process.runSync(binary, ['init-file', dataDir]);
    final payload = _parseSync(r.exitCode, r.stdout as String, r.stderr as String);
    if (payload.isNotEmpty) {
      try {
        await File(_authFile(dataDir)).writeAsString(payload);
      } catch (_) {
        // 锚点保存失败不阻断初始化（后续会话将重新补建）
      }
    }
    return payload;
  }

  /// 初始化 vault（口令模式，可选高级）：授权侧份额 = Argon2id(password)。
  /// 口令经 stdin 首行传递，绝不落 argv；返回并保存会话锚点 T。
  static Future<String> initPassword(String dataDir, String password) async {
    final Process p;
    try {
      p = await Process.start(binary, ['init-password', dataDir]);
    } on ProcessException catch (e) {
      throw VaultException('vault 进程启动失败：${e.message}');
    }
    p.stdin.write('$password\n');
    await p.stdin.flush();
    await p.stdin.close();
    final out = await p.stdout.transform(utf8.decoder).join();
    final err = await p.stderr.transform(utf8.decoder).join();
    final payload = _parseSync(await p.exitCode, out, err);
    if (payload.isNotEmpty) {
      try {
        await File(_authFile(dataDir)).writeAsString(payload);
      } catch (_) {}
    }
    return payload;
  }

  /// 初始化 vault（设备绑定多封装，BitLocker 式增强项，opt-in）：
  /// 本机免密（设备熵）+ 可选恢复口令。**涉及设备指纹采集（仅本机读取、
  /// 不上传）——调用方须先向用户明示隐私提示**（device-bound-vault-plan §1.3）。
  /// [recoveryPassword] 非 null 时经 stdin 首行传递，绝不落 argv。
  static Future<String> initDevice(String dataDir,
      {String? recoveryPassword}) async {
    final Process p;
    try {
      p = await Process.start(
          binary, ['init-device', dataDir, if (recoveryPassword != null) '--set-recovery-password']);
    } on ProcessException catch (e) {
      throw VaultException('vault 进程启动失败：${e.message}');
    }
    if (recoveryPassword != null) {
      p.stdin.write('$recoveryPassword\n');
      await p.stdin.flush();
    }
    await p.stdin.close();
    final out = await p.stdout.transform(utf8.decoder).join();
    final err = await p.stderr.transform(utf8.decoder).join();
    final payload = _parseSync(await p.exitCode, out, err);
    if (payload.isNotEmpty) {
      try {
        await File(_authFile(dataDir)).writeAsString(payload);
      } catch (_) {}
    }
    return payload;
  }

  /// 是否已初始化（解析 status JSON；未初始化时后续会话将被拒）。
  static Future<bool> isInitialized(String dataDir) async {
    final r = Process.runSync(binary, ['status', dataDir]);
    return _parseSync(r.exitCode, r.stdout as String, r.stderr as String)
        .contains('"initialized":true');
  }

  /// 份额锚定模式：`crypto`（LEGACY 单因子）| `os`（OS 份额）| `password`
  /// （口令派生）| `multiseal`（设备绑定）。
  /// **未初始化（`initialized:false`，无 mode 字段）返回 null**——具体加密
  /// 方案由 prefs 偏好兜底（[SecurityPrefs.credentialScheme]，默认 crypto）；
  /// 仅 status 异常/二进制缺失（解析抛 [VaultException]）同样由调用方兜底为 null。
  static Future<String?> mode(String dataDir) async {
    final r = Process.runSync(binary, ['status', dataDir]);
    final payload = _parseSync(r.exitCode, r.stdout as String, r.stderr as String);
    final mode = RegExp(r'"mode":"(\w+)"').firstMatch(payload)?.group(1);
    if (mode != null) return mode;
    // 未初始化（无 mode 字段）→ null（不虚构默认 v1：默认方案由 prefs 决定）
    return null;
  }

  /// 份额后端（v4 指纹，status JSON `"backend"`）：`file`=文件密钥模式 /
  /// `dpapi`/`keychain`/`libsecret`/`insecure`=OS 安全存储。crypto 模式由
  /// 本字段区分「OS 存储」与「文件密钥」两种实现；未初始化返回 null。
  static Future<String?> backend(String dataDir) async {
    final r = Process.runSync(binary, ['status', dataDir]);
    final payload = _parseSync(r.exitCode, r.stdout as String, r.stderr as String);
    return RegExp(r'"backend":"(\w+)"').firstMatch(payload)?.group(1);
  }

  /// 设备绑定（v3）是否设置了恢复口令封装（kind=1）——决定关闭绑定时是
  /// 「验证恢复口令」还是「新设 v2 口令」（纯熵绑定对称于免密开启，无需口令）。
  /// 非 multiseal 一律返回 false。
  static Future<bool> hasRecovery(String dataDir) async {
    final r = Process.runSync(binary, ['status', dataDir]);
    final payload = _parseSync(r.exitCode, r.stdout as String, r.stderr as String);
    return payload.contains('"has_recovery":true');
  }

  /// 修改恢复口令（多封装，须已解锁）：旧口令立即失效。
  /// [password] 为当前会话解锁口令（v3 换机恢复场景）。
  static Future<void> setRecoveryPassword(String dataDir, String newPassword,
      {String? password}) async {
    final s = await _VaultSession.open(dataDir, password: password);
    try {
      await s.send(
          'set-recovery-password ${base64Encode(utf8.encode(newPassword))}');
    } finally {
      await s.close();
    }
  }

  /// 清除恢复口令（多封装，须已解锁）：换机/熵丢失后不可恢复，须谨慎调用。
  /// 返回是否实际清除了。
  static Future<bool> clearRecoveryPassword(String dataDir,
      {String? password}) async {
    final s = await _VaultSession.open(dataDir, password: password);
    try {
      return await s.send('clear-recovery-password') == 'true';
    } finally {
      await s.close();
    }
  }

  /// 重新绑定当前设备（多封装，须已解锁；换机口令恢复后调用）：
  /// 用当前设备指纹重密封熵，旧指纹立即失效。返回新熵标识（base64）。
  static Future<String> rebind(String dataDir, {String? password}) async {
    final s = await _VaultSession.open(dataDir, password: password);
    try {
      return await s.send('rebind');
    } finally {
      await s.close();
    }
  }

  /// 升级为设备绑定（v1/v2 → v3，§8 迁移）：既有 vault 解锁后补建
  /// 多封装——生成熵写 device.seal + 熵密封 S（kind=2），可选恢复口令
  /// （kind=1）。**key_vault 与 K 不变，既有条目直接沿用（无需重加密）**。
  /// v2（口令模式）须传 [password]（当前会话口令）；v1（OS 模式）无需。
  /// [recoveryPassword] 非 null 时补建口令封装（换机恢复路径）。
  /// 返回新熵标识（base64）。涉及设备指纹采集——调用方须先明示隐私提示。
  static Future<String> upgradeDevice(String dataDir,
      {String? recoveryPassword, String? password}) async {
    final s = await _VaultSession.open(dataDir, password: password);
    try {
      if (recoveryPassword != null) {
        return await s.send(
            'upgrade-device --set-recovery-password ${base64Encode(utf8.encode(recoveryPassword))}');
      }
      return await s.send('upgrade-device');
    } finally {
      await s.close();
    }
  }

  /// v1 ↔ v2 份额迁移（三档切换条：系统保护 ↔ 口令保护）：
  /// 份额源在 OS 安全存储 ↔ Argon2id 口令间切换，**主密钥 K 不变，
  /// 既有条目直接沿用（无需重加密）**。
  ///   target='password'（v1 → v2）：[newPassword] 为新会话口令（必填）
  ///   target='os'（v2 → v1）：无需口令（会话已解锁持 K）
  /// [password] 为当前会话口令（v2 → v1 时必填；v1 → v2 时 OS 模式无需）。
  /// 切换成功后既有数据全部保留；下次启动按新模式解锁。
  static Future<void> switchMode(String dataDir, String target,
      {String? newPassword, String? password}) async {
    final s = await _VaultSession.open(dataDir, password: password);
    try {
      if (newPassword != null) {
        await s.send(
            'switch-mode $target ${base64Encode(utf8.encode(newPassword))}');
      } else {
        await s.send('switch-mode $target');
      }
    } finally {
      await s.close();
    }
  }

  /// 关闭设备绑定（清除熵封装，回落口令模式，须已解锁会话）。
  /// 走 `clear-device-seal <b64口令>` serve 命令——[recoveryPassword] 语义按
  /// 封装状态分流：
  ///   - 有恢复口令封装：为当前恢复口令（授权本关闭，口令即新会话口令）；
  ///   - 无（纯熵绑定，开启时免密）：为新设的 v2 解锁口令（免授权校验，
  ///     对称于免密开启）。
  /// 关闭后 vault 降级为 v2 口令模式。返回是否成功关闭。
  static Future<bool> clearDeviceSeal(String dataDir, String recoveryPassword,
      {String? password}) async {
    final s = await _VaultSession.open(dataDir, password: password);
    try {
      return await s.send(
              'clear-device-seal ${base64Encode(utf8.encode(recoveryPassword))}') ==
          'true';
    } finally {
      await s.close();
    }
  }

  /// 全量销毁：删 OS 授权份额 + vault 文件 + 本地锚点/标记（密文不可恢复）。
  static void destroy(String dataDir) {
    final r = Process.runSync(binary, ['destroy', dataDir]);
    _parseSync(r.exitCode, r.stdout as String, r.stderr as String);
    for (final f in [_authFile(dataDir), _markerFile(dataDir)]) {
      try {
        final file = File(f);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }

  // ── 凭据命令（会话模式）───────────────────────────────────────────

  /// 读取凭据明文（base64 载荷；无条目返回 null）。
  /// 口令模式 vault 须传 [password]（握手第 4 字段，用后即弃不缓存）。
  static Future<String?> get(String dataDir, String uid,
      {String? password}) async {
    final s = await _VaultSession.open(dataDir, password: password);
    try {
      final payload = await s.send('get $uid');
      return payload == 'null' ? null : payload;
    } finally {
      await s.close();
    }
  }

  /// 写入凭据（明文 [plaintext] 经 stdin 传递，不落 argv）。
  /// 口令模式 vault 须传 [password]。
  static Future<void> set(String dataDir, String uid, String plaintext,
      {String? password}) async {
    final s = await _VaultSession.open(dataDir, password: password);
    try {
      await s.send('set $uid', payloadLine: base64Encode(utf8.encode(plaintext)));
    } finally {
      await s.close();
    }
  }

  /// 删除单条凭据。口令模式 vault 须传 [password]。
  static Future<void> delete(String dataDir, String uid,
      {String? password}) async {
    final s = await _VaultSession.open(dataDir, password: password);
    try {
      await s.send('delete $uid');
    } finally {
      await s.close();
    }
  }

  // ── 崩溃联动标记（§3.7）───────────────────────────────────────────

  /// 读取并消费退出标记：上次会话异常退出（crash）返回 true（启动显著警告用）。
  /// 读取即删除（一次性消费，避免每次启动重复提示）。
  static bool consumeCrashMarker(String dataDir) {
    try {
      final f = File(_markerFile(dataDir));
      if (!f.existsSync()) return false;
      final marker = f.readAsStringSync().trim();
      f.deleteSync();
      return marker == markerCrash;
    } catch (_) {
      return false;
    }
  }

  // ── 内部 ─────────────────────────────────────────────────────────

  static String _authFile(String dataDir) => '$dataDir/vault.auth';
  static String _markerFile(String dataDir) => '$dataDir/vault.marker';

  /// spawn 方声明父进程白名单（血缘校验，vault 侧据此拒绝独立/脚本调用）。
  static String _parentNames() {
    final me = Platform.resolvedExecutable.split(Platform.pathSeparator).last;
    return [me, 'flutter_tester', 'dart', 'dart_tests', 'flutter']
        .where((n) => n.isNotEmpty)
        .join(',');
  }

  static final Random _rng = Random.secure();

  static String _randomB64(int n) =>
      base64Encode(List<int>.generate(n, (_) => _rng.nextInt(256)));

  static bool _eqBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }

  /// 会话退出记录：写标记 + 非预期（crash）联动终止主进程。
  static Future<void> _record(String dataDir, int code,
      {required bool normal}) async {
    final String marker;
    if (!normal || code < 0) {
      marker = markerCrash; // 信号终止 / 挂起 / 无响应 EOF：非预期
    } else if (code == 0) {
      marker = markerOk;
    } else {
      marker = markerFail; // vault 主动报错退出（如解锁失败），不联动
    }
    try {
      await File(_markerFile(dataDir)).writeAsString(marker);
    } catch (_) {}
    if (marker == markerCrash) _abort(dataDir);
  }

  /// fail-closed：非预期退出 → 连带终止主进程（物理内存随系统回收）。
  /// `ARCHOERA_VAULT_NO_ABORT=1`（测试/CI）仅写标记不终止。
  static void _abort(String dataDir) {
    stderr.writeln('[vault] 凭据模块异常退出，fail-closed 终止主进程（$dataDir）');
    if (Platform.environment[envNoAbort] == '1') return;
    exit(86);
  }

  static String _parseSync(int code, String out, String err) {
    final line = out.trim();
    if (code != 0 || line.isEmpty || line.startsWith('err ')) {
      final msg = line.startsWith('err ')
          ? line.substring(4)
          : (line.isEmpty ? err.trim() : line);
      throw _asException(msg.isEmpty ? 'vault 进程异常退出（code=$code）' : msg);
    }
    return line.startsWith('ok ') ? line.substring(3) : '';
  }

  /// 按消息内容分类异常（前缀错误码，v4 服务端分类）：
  ///   `NEED_RECOVERY` → [VaultNeedRecoveryException]（设备变更/熵损坏，有口令封装可恢复）
  ///   `SHARE_BACKEND_MISMATCH` → [VaultShareBackendMismatchException]（v4 指纹校验）
  ///   `SHARE_MISSING` → [VaultShareMissingException]（授权侧份额缺失）
  ///   `SHARE_MISMATCH` → [VaultShareMismatchException]（GCM 认证失败，份额/口令不配对）
  ///   其余 → [VaultException]。
  static VaultException _asException(String message) {
    if (message.startsWith('NEED_RECOVERY ')) {
      return VaultNeedRecoveryException(message);
    }
    if (message.startsWith('SHARE_BACKEND_MISMATCH ')) {
      return VaultShareBackendMismatchException(message);
    }
    if (message.startsWith('SHARE_MISSING ')) {
      return VaultShareMissingException(message);
    }
    if (message.startsWith('SHARE_MISMATCH ')) {
      return VaultShareMismatchException(message);
    }
    return VaultException(message);
  }

  /// 锚点校验/保存：首次（无本地文件）保存；已有 → 必须一致
  /// （不一致 = vault 文件被替换 → 拒绝服务）。
  ///
  /// 格式统一为 base64 字符串（与 [init] 的 `writeAsString(payload)` 一致）；
  /// 兼容读取旧版本（早期 [writeAsBytes] 写入的 16 字节二进制锚点）——
  /// UTF-8 解码随机二进制必然失败，须回退按原始字节比对，否则误判为
  /// 文件损坏 → fail-closed 崩掉整个应用（2026-08-13 修复实录）。
  static Future<void> _verifyAnchor(String dataDir, List<int> t) async {
    final f = File(_authFile(dataDir));
    if (!f.existsSync()) {
      await f.writeAsString(base64Encode(t));
      return;
    }
    final raw = f.readAsBytesSync();
    List<int>? saved;
    try {
      saved = base64Decode(String.fromCharCodes(raw).trim());
    } catch (_) {
      saved = raw; // 旧格式（二进制锚点）：按原始字节比对
    }
    if (!_eqBytes(saved, t)) {
      throw VaultException('vault 锚点不一致：凭据库可能已被替换，拒绝服务');
    }
  }

  /// 版本异常公共收尾（同步，fail-closed）：
  /// 1) 删除异常 vault 二进制副本（防再次被加载/被滥用；[deletePath] 优先，
  ///    否则回退 [_binary]——`_verifyProduction` 在解析链中触发时 `_binary`
  ///    尚未赋值，必须显式传 [deletePath]；env 显式指定即测试/CI 信任边界，
  ///    不删——测试产物本就该在测试目录）；
  /// 2) 失效二进制缓存：后续 [available]/[binary] 均失败（vault 不可用）；
  /// 3) 置 [versionFatal]（结构化原因枚举）：UI 顶层据此显示「仅允许用户退出」页，
  ///    展示文案由 UI 层按枚举映射 l10n（本层只写技术日志，不承载展示文案）。
  static void _failVersion(VaultFatalReason reason,
      {required String log, String? deletePath}) {
    stderr.writeln('[vault] $log');
    final target = deletePath ?? _binary;
    if (!_binaryFromEnv && target != null) {
      try {
        final f = File(target);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        stderr.writeln('[vault] 删除异常 vault 副本失败，请手动清理 $target');
      }
    }
    _binary = null;
    _binaryFromEnv = false;
    _verifiedBinary = null;
    versionFatal.value = reason;
  }

  /// 握手版本异常处理（fail-closed，[VaultVersionException] 触发）：
  /// 进程终止、删除副本、失效缓存、[versionFatal] 置位（公共部分见 [_failVersion]），
  /// 另写 fail 标记。进程终止与 fail 标记由调用方 catch 路径负责（VaultException 语义）。
  static Future<void> _handleVersionAnomaly(String dataDir, Process p,
      VaultFatalReason reason, String log) async {
    _failVersion(reason, log: log);
    try {
      p.kill(ProcessSignal.sigkill);
    } catch (_) {}
    try {
      await File(_markerFile(dataDir)).writeAsString(markerFail);
    } catch (_) {}
  }
}

/// vault 版本异常原因（结构化枚举，UI 按此映射 l10n 文案）：
///   - [binaryReplaced]：`--version` 生产标记校验失败（默认路径二进制被替换/
///     非官方构建/损坏），副本已删除、解密被拒；
///   - [markerMissing]：握手应答缺少构建标记（版本协议不符/旧版二进制）；
///   - [markerMismatch]：握手应答构建标记非官方生产（PROD）标记。
enum VaultFatalReason { binaryReplaced, markerMissing, markerMismatch }

/// 单个 serve 会话：握手完成后持有，命令经 stdin/stdout 行协议。
class _VaultSession {
  _VaultSession._(this._p, this._dataDir);

  final Process _p;
  final String _dataDir;
  final _LineReader _reader = _LineReader();
  bool _closed = false;

  /// spawn + 握手。失败时按退出路径记录标记（fail/crash）并抛 [VaultException]。
  /// 口令模式 vault 须传 [password]（握手第 4 字段 base64；用后即弃不缓存）。
  static Future<_VaultSession> open(String dataDir,
      {String? password}) async {
    final Process p;
    try {
      p = await Process.start(VaultProcess.binary, ['serve', dataDir],
          environment: {
            ...Platform.environment,
            VaultProcess.envParentOk: VaultProcess._parentNames(),
          });
    } on ProcessException catch (e) {
      throw VaultException('vault 进程启动失败：${e.message}');
    }
    final s = _VaultSession._(p, dataDir);
    s._reader.attach(
        p.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    // stderr 仅作日志（不解析协议）
    p.stderr.transform(utf8.decoder).listen((l) {
      stderr.write('[vault] $l');
    }, onError: (_) {});

    final h = VaultProcess._randomB64(32);
    final c = VaultProcess._randomB64(16);
    final handshake = password == null
        ? 'handshake $h $c\n'
        : 'handshake $h $c ${base64Encode(utf8.encode(password))}\n';
    try {
      p.stdin.write(handshake);
      await p.stdin.flush();
      final line = await s._reader
          .next()
          .timeout(VaultProcess.handshakeTimeout);
      final parts = line.split(' ');
      if (parts.length < 4 || parts[0] != 'ok' || parts[1] != 'handshake') {
        // vault 主动拒绝（未初始化/血缘不符/NEED_RECOVERY 等）：预期失败路径
        final msg = parts.length >= 2 && parts[0] == 'err'
            ? parts.sublist(1).join(' ')
            : line;
        final code = await p.exitCode.timeout(VaultProcess._cmdTimeout,
            onTimeout: () => -1);
        await VaultProcess._record(dataDir, code, normal: code >= 0);
        throw VaultProcess._asException(msg);
      }
      final t = base64Decode(parts[2]);
      final mac = base64Decode(parts[3]);
      // 应答验证：HMAC-SHA256(H, C) 可自算比对（通道/存活确认）
      final expected =
          crypto.Hmac(crypto.sha256, base64Decode(h)).convert(base64Decode(c)).bytes;
      if (!VaultProcess._eqBytes(mac, expected)) {
        p.kill(ProcessSignal.sigkill);
        await VaultProcess._record(dataDir, -1, normal: false);
        throw VaultException('vault 握手应答校验失败');
      }
      // 握手版本指纹（默认路径二进制校验，fail-closed）：
      // 应答第 5 字段 = 构建标记（BuildInfo.Marker）。默认路径解析的 vault
      // 必须是官方生产构建（PROD 标记）——TEST 标记/缺失 = 测试或已替换的
      // 二进制（携带 INSECURE_FILE_STORE 显式启动指令）→ 删除副本 + 拒绝
      // 解密 + versionFatal（UI 仅允许退出）。env 显式指定（测试/CI 信任
      // 边界）跳过校验，但标记存在性仍校验（防旧版协议误判）。
      final marker = parts.length >= 5 ? parts[4] : '';
      if (parts.length < 5 || marker.isEmpty) {
        await VaultProcess._handleVersionAnomaly(dataDir, p,
            VaultFatalReason.markerMissing, 'handshake missing build marker');
        throw VaultVersionException(
            'vault 版本异常：应答缺少构建标记，已拒绝解密');
      }
      if (!VaultProcess._binaryFromEnv &&
          !marker.startsWith(VaultProcess._prodMarker)) {
        await VaultProcess._handleVersionAnomaly(dataDir, p,
            VaultFatalReason.markerMismatch,
            'handshake marker mismatch: $marker');
        throw VaultVersionException(
            'vault 版本异常：检测到非官方构建标记 $marker，已删除副本并拒绝解密');
      }
      // 锚点校验（文件被替换 → 拒绝）
      await VaultProcess._verifyAnchor(dataDir, t);
      return s;
    } on TimeoutException {
      // 握手超时：vault 挂起/异常 → 非预期
      p.kill(ProcessSignal.sigkill);
      await VaultProcess._record(dataDir, -1, normal: false);
      throw VaultException('vault 握手超时');
    } catch (e) {
      // 其他失败（锚点不一致等主动拒绝 / 未知异常）：终止会话进程防泄漏。
      // - VaultException = vault 侧健康、主进程主动拒绝 → fail 标记（不联动）
      // - 其余 = 非预期 → crash 标记
      final refusal = e is VaultException;
      try {
        p.kill(ProcessSignal.sigkill);
      } catch (_) {}
      await VaultProcess._record(dataDir, refusal ? 1 : -1, normal: refusal);
      if (e is VaultException) rethrow;
      throw VaultException('vault 握手失败：$e');
    }
  }

  /// 发送命令（[payloadLine] 为 set 的第二行明文负载）；返回响应载荷。
  /// vault `err` 响应 → 抛 [VaultException]（会话仍可继续/退出）。
  Future<String> send(String line, {String? payloadLine}) async {
    final w = _p.stdin;
    w.write('$line\n');
    if (payloadLine != null) w.write('$payloadLine\n');
    await w.flush();
    final resp = await _reader.next().timeout(VaultProcess._cmdTimeout);
    if (resp.startsWith('err ')) {
      throw VaultProcess._asException(resp.substring(4));
    }
    return resp.startsWith('ok ') ? resp.substring(3) : resp;
  }

  /// 正常收尾：`quit` → 等退出 → 记录标记。重复调用幂等。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    var normal = true;
    try {
      await send('quit').timeout(const Duration(seconds: 5));
    } catch (_) {
      // quit 无响应（vault 挂起/已死）→ 非预期
      normal = false;
    }
    if (!normal) {
      try {
        _p.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
    var code = -1;
    try {
      code = await _p.exitCode.timeout(const Duration(seconds: 5),
          onTimeout: () => -1);
    } catch (_) {}
    await VaultProcess._record(_dataDir, code, normal: normal);
  }
}

/// stdout 行缓冲 reader（支持并发 next 请求；超时由调用方 timeout 施加）。
class _LineReader {
  final List<String> _buffer = [];
  final List<Completer<String>> _waiters = [];
  StreamSubscription<String>? _sub; // ignore: unused_field —— 持有订阅引用防流被回收
  bool _done = false;

  void attach(Stream<String> lines) {
    _sub = lines.listen(_onData, onError: (_) {}, onDone: () => _done = true);
  }

  void _onData(String line) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(line);
    } else {
      _buffer.add(line);
    }
  }

  Future<String> next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    if (_done) return Future.error(StateError('vault stdout 已关闭（EOF）'));
    final c = Completer<String>();
    _waiters.add(c);
    return c.future;
  }
}

/// vault 操作失败（进程退出非零 / `err` 响应 / 二进制缺失 / 握手/锚点校验失败）。
class VaultException implements Exception {
  const VaultException(this.message);

  final String message;

  @override
  String toString() => 'VaultException: $message';
}

/// 设备变更/熵文件损坏且 vault 有口令封装：需「恢复口令」解锁（serve `err NEED_RECOVERY`）。
/// 与普通解锁失败的区别：不计入锁定退避、UI 应弹恢复流而非报错。
class VaultNeedRecoveryException extends VaultException {
  const VaultNeedRecoveryException(super.message);

  @override
  String toString() => 'VaultNeedRecoveryException: $message';
}

/// 份额不配对（serve `err SHARE_MISMATCH`，GCM 认证失败）：vault 文件与授权侧
/// 份额 S 不配对——口令错误 / 份额被替换 / 文件被篡改。已触发锁定退避，
/// UI 应提示「凭据保险库不配对，需销毁重建」。
class VaultShareMismatchException extends VaultException {
  const VaultShareMismatchException(super.message);

  @override
  String toString() => 'VaultShareMismatchException: $message';
}

/// 授权侧份额缺失（serve `err SHARE_MISSING`）：vault 文件存在但对应后端
/// 无 S 份额，数据不可恢复——UI 应引导销毁重建。
class VaultShareMissingException extends VaultException {
  const VaultShareMissingException(super.message);

  @override
  String toString() => 'VaultShareMissingException: $message';
}

/// 份额后端不配对（serve `err SHARE_BACKEND_MISMATCH`，v4 指纹校验）：vault
/// 文件头记录的 backend ≠ 当前实际存储后端——不同构建形态（PROD=OS 安全存储 /
/// TEST=明文文件）混用同一数据目录所致，S 份额与凭据库永久不配对。
/// 非爆破向量（不触发锁定退避）；UI 应明确引导「销毁重建」而非反复重试。
class VaultShareBackendMismatchException extends VaultException {
  const VaultShareBackendMismatchException(super.message);

  @override
  String toString() => 'VaultShareBackendMismatchException: $message';
}

/// vault 版本/构建标记异常（握手应答 marker 非 PROD 或缺失，仅默认路径
/// 二进制触发）：副本已删除、解密已拒绝、[VaultProcess.versionFatal] 已置位——
/// UI 显示「仅允许用户退出」页（fail-closed，不降级）。
class VaultVersionException extends VaultException {
  const VaultVersionException(super.message);

  @override
  String toString() => 'VaultVersionException: $message';
}
