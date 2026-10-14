// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import '../log/log.dart';
import '../native_integrity.dart';
import '../../utils/safe_file.dart';

/// 凭据保险库进程（`archoera-vault`，三端 Rust 静态可执行）封装。
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
  static const String envNoAbort = 'ARCHOERA_VAULT_NO_ABORT';

  /// 加载器注入环境变量（spawn vault 前必须剔除）：
  /// Linux `LD_PRELOAD`/`LD_AUDIT` 可在动态装载时劫持 vault 的 `read`/握手
  /// 从而窃取 stdin 上的口令；macOS `DYLD_INSERT_LIBRARIES` 同理。
  /// `LD_LIBRARY_PATH` 常被合法使用，一并剔除以缩小库搜索面（同属加载路径操纵）。
  /// 其余环境（locale / OS 钥匙串后端 / D-Bus 地址等）必须保留。
  static const List<String> loaderInjectionVars = [
    'LD_PRELOAD',
    'LD_AUDIT',
    'LD_LIBRARY_PATH',
    'DYLD_INSERT_LIBRARIES',
    'DYLD_LIBRARY_PATH',
    'DYLD_FRAMEWORK_PATH',
  ];

  /// 构建 spawn vault 用的净化环境：`Platform.environment` 去掉
  /// [loaderInjectionVars]。spawn 时必须 **同时** 传
  /// `includeParentEnvironment: false`——Dart 默认把 `environment` 与父进程环境
  /// 合并，仅传净化表无法真正移除注入变量（父进程的 `LD_PRELOAD` 仍会被继承）。
  /// [from] 仅测试注入（默认取真实 [Platform.environment]）。
  @visibleForTesting
  static Map<String, String> sanitizedEnvironment([Map<String, String>? from]) {
    final env = Map<String, String>.of(from ?? Platform.environment);
    for (final key in loaderInjectionVars) {
      env.remove(key);
    }
    return env;
  }

  /// 是否允许 `ARCHOERA_VAULT_BIN` 覆盖 vault 二进制路径：仅 debug/test 构建
  /// （`kDebugMode`，含 `flutter test`），或以 `--dart-define=ARCHOERA_ALLOW_VAULT_BIN=true`
  /// 显式放宽（默认关闭）。release 构建**忽略**该环境变量，改走默认路径解析
  /// （经 SEC-08 清单验签 + 生产标记 + 血缘校验），防攻击者用自选二进制接收明文口令。
  static bool get _allowEnvBin =>
      kDebugMode || const bool.fromEnvironment('ARCHOERA_ALLOW_VAULT_BIN');

  /// 「沙箱被蓄意破坏」专用退出码（与 vault 侧 `guard::SANDBOX_BREACH_EXIT` 对齐）：
  /// 可观测的蓄意破坏（加载器注入变量等）→ vault 自毁退出 87 → 本层与「异常退出」
  /// 同等对待（crash 标记 → [exit(86)] 连带主程序退出）。
  static const int sandboxBreachExit = 87;

  static const String markerOk = 'ok';
  static const String markerCrash = 'crash';
  static const String markerFail = 'fail';

  static const Duration handshakeTimeout = Duration(seconds: 10);
  static const Duration _cmdTimeout = Duration(seconds: 15);

  /// 候选相对路径（bundle `native/` 平铺优先，dev 产物目录兜底）。
  /// vault 为三端 Rust 版：dev 产物在 `core/vault-rs/build/`（`vault-rs/build.sh`）；
  /// C# 版（`core/vault/`）已于 2026-10-12 删除。
  static const List<String> _candidates = [
    'native',
    'core/vault-rs/build',
    'vault-rs/build',
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
    // Vector C：仅 debug/test 构建信任 `ARCHOERA_VAULT_BIN`（release 忽略，
    // 走默认路径解析 → 经 SEC-08 清单校验 + 生产标记 + 血缘校验）。
    final env = _allowEnvBin ? Platform.environment[envBin] : null;
    if (env != null && env.isNotEmpty) {
      // 显式 ARCHOERA_VAULT_BIN（测试/CI/高级用户）：信任该二进制，不做
      // 生产标记校验——设置进程环境本身即需系统权限，生产路径绝不设置；
      // 但 SEC-08 清单校验仍适用：清单锚定可执行文件（非环境变量），
      // 不因 env 指定二进制而被劫持；无清单时开发态跳过。
      _binaryFromEnv = true;
      if (File(env).existsSync()) {
        final p = File(env).absolute.path;
        NativeIntegrity.verifyOrThrow(p);
        return p;
      }
      final inDir = File('$env/$_exeName');
      if (inDir.existsSync()) {
        final p = inDir.absolute.path;
        NativeIntegrity.verifyOrThrow(p);
        return p;
      }
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
      throw VaultException('未找到 $_exeName（bundle/native 或 core/vault-rs/build）');
    }
    // SEC-08：加载/执行（--version）前先校验原生完整性清单——签名存在则
    // fail-closed 验签 + 摘要，避免执行可能被篡改的 vault 字节。
    NativeIntegrity.verifyOrThrow(found);
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
  ///
  /// **本处保留同步 `Process.runSync`（有意）**：它由同步 getter [binary] →
  /// [_resolveBinary] 触达，改成异步会牵动 `binary` 的整个同步调用面；而
  /// `--version` 是**无外部 I/O 的本地探测**（不碰钥匙串/网络/DBus），
  /// 实际不可阻塞。会因外部后端（如 Linux Secret Service）无响应而挂起的
  /// 是 `status` / `init-*` / `destroy` —— 它们一律走 [_runBounded]。
  static void _verifyProduction(String path) {
    if (_verifiedBinary == path) return;
    final r = Process.runSync(path, ['--version'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: sanitizedEnvironment(),
        includeParentEnvironment: false);
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

  /// 有界执行单命令 vault 进程（异步 + 超时）。
  ///
  /// 背景（2026-10-14 全平台 CI 的 Ubuntu job 实录）：这些调用原先是
  /// `Process.runSync(...)` —— **同步阻塞会冻死整个 isolate**，`package:test`
  /// 的超时定时器根本没机会触发，表现就是「日志停住、几十分钟毫无输出」，
  /// 只能人工取消。生产侧同理：vault 子进程一旦不返回（例如 Linux Secret
  /// Service 无响应），宿主 Dart isolate 会被一起冻死。
  ///
  /// 改为异步 + [_cmdTimeout] 后：无响应 → 明确抛 [VaultException]，
  /// 宿主 isolate 不再被堵住。参数**不含凭据**（凭据只经 stdin 传输）。
  static Future<ProcessResult> _runBounded(String exe, List<String> args) async {
    try {
      return await Process.run(
        exe,
        args,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: sanitizedEnvironment(),
        includeParentEnvironment: false,
      ).timeout(_cmdTimeout);
    } on TimeoutException {
      throw VaultException(
          'vault 进程无响应（超过 ${_cmdTimeout.inSeconds}s）：'
          '${args.isEmpty ? exe : args.join(' ')}');
    }
  }

  static String? _verifiedBinary;
  static const String _prodMarker = 'ARCHOERA-VAULT-PROD';

  // ── 生命周期（单命令，不涉凭据读取）────────────────────────────────

  /// 初始化 vault（LEGACY：crypto 传统单因子，推荐）——主密钥 K 整体存
  /// OS 安全存储（DPAPI/Keychain/libsecret），vault 文件不含密钥材料。
  /// 无份额配对、无口令、无设备熵，稳定性高于 2-of-2（不存在份额丢失
  /// 导致的凭据整体丢失）；安全性降为单点（OS 钥匙串被攻破 = 凭据全泄露）。
  /// 返回并保存会话锚点 T（`vault.auth`）。
  /// **LEGACY（`crypto`，依赖系统钥匙串）在*本机*是否真的可用**（切换前预检）。
  ///
  /// 判据只能是「真的建一次库」：`status` 不反映后端能力，而某些平台/环境直接拒绝
  /// （Linux 无 Secret Service 时 `init-crypto` 报 "Secret Service 后端在 V1 中未实现
  /// （请使用 file 后端）"）。因此在**临时目录**里跑一次 `init-crypto` + `destroy`：
  /// 不触碰现有容器，也不会把用户数据留在半初始化状态。
  ///
  /// 为什么必须预检而不能「失败再回滚」：`destroy` 会连**系统钥匙串里的份额**一并删除，
  /// 那是进程外的状态、无法快照恢复——切到 LEGACY 失败后旧方案也回不去了。
  static Future<bool> canInitCrypto() async {
    if (!available) return false;
    final tmp = Directory.systemTemp.createTempSync('archoera-vault-probe');
    try {
      await initCrypto(tmp.path);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        destroy(tmp.path);
      } catch (_) {}
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 是否**免密**方案——只有它们可以在「库缺失」时被**惰性自动初始化**。
  ///
  /// m1 / m2a / m2b 需要用户因子（口令 / `device.key` / 恢复码）：库缺失时**绝不能**
  /// 静默 auto-init 成单因子 `crypto`——那既是**安全降级**（用户选了双因子却得到单因子），
  /// 又会造成「pref 说 m2a、容器是 crypto」的不一致。此类方案交给 UI 的初始化/解锁门
  /// 提示用户显式选择并设置因子。
  static bool isPasswordlessScheme(String scheme) =>
      scheme == 'crypto' || scheme == 'file';

  /// 初始化后**自验证**：用刚设置的口令（m2b/crypto 传 null=免密）真实走一次解锁握手。
  ///
  /// **为什么必须有**：方案切换会先销毁旧库再初始化新方案；若新库初始化「成功」
  /// 但用户输入的口令与写入的因子不一致（臆造/输入法差异/交互流程异常），
  /// 就会出现「新库自己的口令打不开 + 旧库已销毁」＝丢库（真实事故 2026-10-14：
  /// m2a 切换后只能靠恢复码救）。自验证失败 → 调用方回滚快照，旧库原封不动。
  /// 凭据用后即弃，不缓存。
  static Future<void> verifyUnlock(String dataDir, {String? password}) async {
    final _VaultSession s;
    try {
      s = await _VaultSession.open(dataDir, password: password);
    } on VaultVersionException {
      rethrow; // 版本异常有独立 fatal 语义（删副本 + 仅可退出），不包装
    } catch (e) {
      throw VaultException(
          '新库自验证失败：初始化写入的因子无法用刚输入的口令解锁（$e）；已回滚，旧库未动');
    }
    await s.close();
  }

  static Future<String> initCrypto(String dataDir) async {
    final r = await _runBounded(binary, ['init-crypto', dataDir]);
    final payload = _parseSync(r.exitCode, r.stdout as String, r.stderr as String);
    if (payload.isNotEmpty) {
      try {
        SafeFile.writeAtomicString(_authFile(dataDir), payload);
      } catch (_) {
        // 锚点保存失败不阻断初始化（后续会话将重新补建）
      }
    }
    return payload;
  }

  /// 初始化 vault（文件密钥模式，LEGACY 兼容）：主密钥 K 整体落盘
  /// `$dataDir/secret.key`（0600 原子写；若需在初始化时指定 K，须走原生 CLI
  /// `archoera-vault init-file --key-stdin` 经 stdin 传入——**不再支持环境变量注入**，
  /// 原 `ARCHOERA_VAULT_SECRET_KEY` 已按 SEC-02 移除）——免 OS 钥匙串，供无 Secret
  /// Service 的 headless Linux / Docker 使用（经典的服务端加密形态）。
  /// **本地文件单点：密钥文件泄露 = 凭据全泄露（弱于 OS 存储），
  /// 选用即显式接受该降级。** 复用 crypto 单因子全部配套（握手/崩溃联动/
  /// 目录隔离/可销毁）。返回并保存会话锚点 T（`vault.auth`）。
  static Future<String> initFile(String dataDir) async {
    final r = await _runBounded(binary, ['init-file', dataDir]);
    final payload = _parseSync(r.exitCode, r.stdout as String, r.stderr as String);
    if (payload.isNotEmpty) {
      try {
        SafeFile.writeAtomicString(_authFile(dataDir), payload);
      } catch (_) {
        // 锚点保存失败不阻断初始化（后续会话将重新补建）
      }
    }
    return payload;
  }

  /// 初始化 vault（'S' slots，m1 = 仅口令槽）：主密钥 K 由
  /// Argon2id(password) 派生的 KEK 封装在 vault 文件槽位表中（自包含，
  /// 无 OS 钥匙串依赖）；口令经 stdin 首行传递，绝不落 argv。
  /// 可选 [kdfM]/[kdfT]/[kdfP] 指定 Argon2id 强度（非密文，走 argv；
  /// 缺省由 vault 侧取默认档）。返回并保存会话锚点 T（`vault.auth`）。
  static Future<String> initM1(String dataDir, String password,
      {int? kdfM, int? kdfT, int? kdfP}) async {
    final payload = await _spawnCapture(
        ['init-m1', dataDir, ..._kdfArgs(kdfM, kdfT, kdfP)],
        stdinLine: password);
    await _saveAnchor(dataDir, payload);
    return payload;
  }

  /// 初始化 vault（'S' slots，m2a = 口令+设备双因子槽 + 恢复槽）：
  /// 生成 `device.key`（0600）与 32B 恢复码；口令经 stdin 首行传递。
  /// 可选 [kdfM]/[kdfT]/[kdfP] 指定 Argon2id 强度（作用于口令+设备槽）。
  /// 返回会话锚点 T 与**仅此一次输出**的恢复码（调用方须提示用户妥善保存）。
  /// 同时保存锚点。
  static Future<VaultInitM2a> initM2a(String dataDir, String password,
      {int? kdfM, int? kdfT, int? kdfP}) async {
    final payload = await _spawnCapture(
        ['init-m2a', dataDir, ..._kdfArgs(kdfM, kdfT, kdfP)],
        stdinLine: password);
    final sp = payload.indexOf(' ');
    final anchor = sp < 0 ? payload : payload.substring(0, sp);
    final recoveryCode = sp < 0 ? '' : payload.substring(sp + 1).trim();
    if (anchor.isEmpty || recoveryCode.isEmpty) {
      throw VaultException('m2a 初始化响应缺少锚点或恢复码');
    }
    await _saveAnchor(dataDir, anchor);
    return (anchor: anchor, recoveryCode: recoveryCode);
  }

  /// 初始化 vault（'S' slots，m2b = 仅设备槽）：生成 `device.key`（0600），
  /// 本机免密解锁（握手 3 字段）；返回并保存会话锚点 T（`vault.auth`）。
  static Future<String> initM2b(String dataDir) async {
    final payload = await _spawnCapture(['init-m2b', dataDir]);
    await _saveAnchor(dataDir, payload);
    return payload;
  }

  /// 重键口令承载槽的 Argon2id 强度（`set-kdf`，仅 m1/m2a）：以新参数重新
  /// 封装口令槽，**保持主密钥 K 与全部条目不变**（无数据丢失），原子写 + `.bak`。
  /// 口令经 stdin 首行传递，绝不落 argv；[password] 为当前解锁口令（m2a 设备
  /// 因子须可用，否则 vault 返回 `NEED_RECOVERY`）。
  /// 失败映射：`NEED_RECOVERY` / `SHARE_MISMATCH` / 不支持（crypto/file/m2b 的
  /// `err 该模式不支持更改 KDF`）经 [_asException] 归一为既有异常类型。
  static Future<void> setKdf(String dataDir,
      {required int m, required int t, required int p, String? password}) async {
    await _spawnCapture(
      ['set-kdf', dataDir, '--kdf-m', '$m', '--kdf-t', '$t', '--kdf-p', '$p'],
      stdinLine: password ?? '',
    );
  }

  /// 当前口令承载槽的 Argon2id 强度（仅 m1/m2a；status JSON 的 `kdf` 字段）。
  /// crypto/m2b（无口令 KDF）或未初始化返回 null。
  static Future<({int m, int t, int p})?> kdf(String dataDir) async {
    final r = await _runBounded(binary, ['status', dataDir]);
    final payload = _parseSync(r.exitCode, r.stdout as String, r.stderr as String);
    final match = RegExp(r'"kdf":\{"m":(\d+),"t":(\d+),"p":(\d+)\}')
        .firstMatch(payload);
    if (match == null) return null;
    return (
      m: int.parse(match.group(1)!),
      t: int.parse(match.group(2)!),
      p: int.parse(match.group(3)!),
    );
  }

  /// 按需追加 `--kdf-m/--kdf-t/--kdf-p`（三者仅当 [m]/[t]/[p] 全部提供时；
  /// 缺省不追加 → vault 取自身默认档，保持既有行为）。
  static List<String> _kdfArgs(int? m, int? t, int? p) {
    if (m == null || t == null || p == null) return const [];
    return ['--kdf-m', '$m', '--kdf-t', '$t', '--kdf-p', '$p'];
  }

  /// 启动单命令 vault 进程（[stdinLine] 非 null 时作为 stdin 首行写入，
  /// 密文/口令绝不落 argv），返回 `ok` 载荷（`err` 抛 [VaultException]）。
  static Future<String> _spawnCapture(List<String> args,
      {String? stdinLine}) async {
    final Process p;
    try {
      p = await Process.start(binary, args,
          environment: sanitizedEnvironment(),
          includeParentEnvironment: false);
    } on ProcessException catch (e) {
      throw VaultException('vault 进程启动失败：${e.message}');
    }
    if (stdinLine != null) {
      p.stdin.write('$stdinLine\n');
      await p.stdin.flush();
    }
    await p.stdin.close();
    try {
      // 有界收尾：子进程不退出/流不收尾（外部后端无响应等）不得让宿主无限
      // 等待——理由同 [_runBounded]。超时则击杀子进程后明确报错。
      final out =
          await p.stdout.transform(utf8.decoder).join().timeout(_cmdTimeout);
      final err =
          await p.stderr.transform(utf8.decoder).join().timeout(_cmdTimeout);
      final code = await p.exitCode.timeout(_cmdTimeout);
      return _parseSync(code, out, err);
    } on TimeoutException {
      p.kill(ProcessSignal.sigkill);
      throw VaultException(
          'vault 进程无响应（超过 ${_cmdTimeout.inSeconds}s）：${args.join(' ')}');
    }
  }

  /// 保存会话锚点 T（`vault.auth`）；写盘失败不阻断初始化
  /// （后续会话将重新补建）。
  static Future<void> _saveAnchor(String dataDir, String payload) async {
    if (payload.isEmpty) return;
    try {
      SafeFile.writeAtomicString(_authFile(dataDir), payload);
    } catch (_) {}
  }

  /// 是否已初始化（解析 status JSON；未初始化时后续会话将被拒）。
  static Future<bool> isInitialized(String dataDir) async {
    final r = await _runBounded(binary, ['status', dataDir]);
    return _parseSync(r.exitCode, r.stdout as String, r.stderr as String)
        .contains('"initialized":true');
  }

  /// 份额锚定模式：`crypto`（LEGACY 单因子：K 存 OS 安全存储或文件密钥库）|
  /// `m1`（slots 仅口令槽）| `m2a`（slots 口令+设备双因子 + 恢复槽）|
  /// `m2b`（slots 仅设备槽，本机免密）。
  /// **未初始化（`initialized:false`，无 mode 字段）返回 null**——具体加密
  /// 方案由 prefs 偏好兜底（[SecurityPrefs.credentialScheme]，默认 crypto）；
  /// 仅 status 异常/二进制缺失（解析抛 [VaultException]）同样由调用方兜底为 null。
  static Future<String?> mode(String dataDir) async {
    final r = await _runBounded(binary, ['status', dataDir]);
    final payload = _parseSync(r.exitCode, r.stdout as String, r.stderr as String);
    final mode = RegExp(r'"mode":"(\w+)"').firstMatch(payload)?.group(1);
    if (mode != null) return mode;
    // 未初始化（无 mode 字段）→ null（不虚构默认：默认方案由 prefs 决定）
    return null;
  }

  /// 份额后端（v4 指纹，status JSON `"backend"`）：`file`=文件密钥模式 /
  /// `dpapi`/`keychain`/`libsecret`=OS 安全存储 / `none`=slots 自包含。
  /// crypto 模式由本字段区分「OS 存储」与「文件密钥」两种实现；未初始化返回 null。
  static Future<String?> backend(String dataDir) async {
    final r = await _runBounded(binary, ['status', dataDir]);
    final payload = _parseSync(r.exitCode, r.stdout as String, r.stderr as String);
    return RegExp(r'"backend":"(\w+)"').firstMatch(payload)?.group(1);
  }

  /// 全量销毁：删授权侧份额 + vault 文件 + 本地锚点/标记（密文不可恢复）。
  static Future<void> destroy(String dataDir) async {
    final r = await _runBounded(binary, ['destroy', dataDir]);
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
  /// m1/m2a 须传 [password]；m2a 设备因子缺失（NEED_RECOVERY）时改传
  /// [recoveryCode]；crypto/m2b 两者皆无需。
  static Future<String?> get(String dataDir, String uid,
      {String? password, String? recoveryCode}) async {
    final s = await _VaultSession.open(dataDir,
        password: password, recoveryCode: recoveryCode);
    try {
      final payload = await s.send('get $uid');
      return payload == 'null' ? null : payload;
    } finally {
      await s.close();
    }
  }

  /// 写入凭据（明文 [plaintext] 经 stdin 传递，不落 argv）。
  /// m1/m2a 须传 [password]；m2a 恢复路径传 [recoveryCode]。
  static Future<void> set(String dataDir, String uid, String plaintext,
      {String? password, String? recoveryCode}) async {
    final s = await _VaultSession.open(dataDir,
        password: password, recoveryCode: recoveryCode);
    try {
      await s.send('set $uid', payloadLine: base64Encode(utf8.encode(plaintext)));
    } finally {
      await s.close();
    }
  }

  /// 删除单条凭据。m1/m2a 须传 [password]；m2a 恢复路径传 [recoveryCode]。
  static Future<void> delete(String dataDir, String uid,
      {String? password, String? recoveryCode}) async {
    final s = await _VaultSession.open(dataDir,
        password: password, recoveryCode: recoveryCode);
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
      // 非普通文件（被植入 FIFO / 符号链接）→ 视为无标记并忽略：绝不能让读取阻塞界面。
      // 长度上限 64 B（标记词）顺带防超大文件。
      final marker = SafeFile.readString(f.path, maxBytes: 64, allowSymlink: false);
      if (marker == null) return false;
      f.deleteSync();
      return marker == markerCrash;
    } catch (_) {
      return false;
    }
  }

  // ── 内部 ─────────────────────────────────────────────────────────

  static String _authFile(String dataDir) => '$dataDir/vault.auth';
  static String _markerFile(String dataDir) => '$dataDir/vault.marker';

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

  /// 退出码 → 标记判定（纯函数，便于单测；[VaultProcess] 语义见 [_record]）。
  @visibleForTesting
  static String markerForExit(int code, {required bool normal}) {
    if (!normal || code < 0 || code == sandboxBreachExit) {
      // 非预期：信号终止 / 挂起 / 无响应 EOF / **沙箱被蓄意破坏（87）**
      return markerCrash;
    }
    if (code == 0) return markerOk;
    return markerFail; // vault 主动报错退出（如解锁失败），不联动
  }

  /// 会话退出记录：写标记 + 非预期（含沙箱被破坏 87）联动终止主进程。
  static Future<void> _record(String dataDir, int code,
      {required bool normal}) async {
    final String marker = markerForExit(code, normal: normal);
    try {
      SafeFile.writeAtomicString(_markerFile(dataDir), marker);
    } catch (_) {}
    if (marker == markerCrash) _abort(dataDir);
  }

  /// fail-closed：非预期退出 → 连带终止主进程（物理内存随系统回收）。
  /// `ARCHOERA_VAULT_NO_ABORT=1`（测试/CI）仅写标记不终止。
  static void _abort(String dataDir) {
    Log.f('vault', '凭据模块异常退出，fail-closed 终止主进程（$dataDir）');
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
    final kind = FileSystemEntity.typeSync(f.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) {
      SafeFile.writeAtomicString(f.path, base64Encode(t)); // 首次：建立锚点（TOFU 引导）
      return;
    }
    // 锚点文件必须是**普通文件**（allowSymlink:false）：被植入 FIFO / 符号链接 / 设备时
    // 直接 fail-closed —— 否则 `readAsBytesSync` 会阻塞（FIFO）或顺着链接读别处。
    final raw = SafeFile.readBytes(f.path, maxBytes: 4096, allowSymlink: false);
    if (raw == null) {
      throw VaultException('vault 锚点文件异常（$kind）：拒绝服务');
    }
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
    Log.e('vault', log);
    final target = deletePath ?? _binary;
    if (!_binaryFromEnv && target != null) {
      try {
        final f = File(target);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        Log.e('vault', '删除异常 vault 副本失败，请手动清理 $target');
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

/// m2a 初始化结果：会话锚点（已保存于 `vault.auth`）+ 仅此一次展示的恢复码。
typedef VaultInitM2a = ({String anchor, String recoveryCode});

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
  /// 握手字段数/标签按 vault 模式（status 读取）构造：crypto/m2b → 3 字段
  /// （免密）；m1 → 第 4 字段 [password]；m2a → 第 4 字段 [password]
  /// （+device.key），或 [recoveryCode] 作第 4 字段 + `b64("rec")` 标签
  /// （第 5 字段）。凭据用后即弃不缓存。
  static Future<_VaultSession> open(String dataDir,
      {String? password, String? recoveryCode}) async {
    final mode = await VaultProcess.mode(dataDir);
    final h = VaultProcess._randomB64(32);
    final c = VaultProcess._randomB64(16);
    final handshake = _handshakeLine(mode, h, c,
        password: password, recoveryCode: recoveryCode);
    final Process p;
    try {
      p = await Process.start(VaultProcess.binary, ['serve', dataDir],
          environment: VaultProcess.sanitizedEnvironment(),
          includeParentEnvironment: false);
    } on ProcessException catch (e) {
      throw VaultException('vault 进程启动失败：${e.message}');
    }
    final s = _VaultSession._(p, dataDir);
    // 宽松 UTF-8 解码（allowMalformed）：vault 侧已强制 UTF-8 输出，但若
    // 混入旧版/非 UTF-8 二进制（如 wine 下 GBK 错误消息），严格解码会抛错
    // 导致协议行丢失 → 握手超时 → fail-closed 崩溃（2026-08-15 修复实录）。
    // 宽松模式把非法字节替换为 U+FFFD，行结构（err/ok 前缀与错误码）不受影响。
    s._reader.attach(p.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter()));
    // stderr 仅作日志（不解析协议）：按内容分级后并入统一日志。
    p.stderr.transform(utf8.decoder).listen((l) {
      final line = l.trimRight();
      if (line.isEmpty) return;
      Log.at(_vaultStderrLevel(line), 'vault', line);
    }, onError: (_) {});

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

  /// 按模式构造握手首行（含 `\n`）：
  ///   crypto / m2b → `handshake <H> <C>`（免密 3 字段）；
  ///   m1 → `handshake <H> <C> <b64口令>`（4 字段）；
  ///   m2a → `handshake <H> <C> <b64口令>`（4 字段，+device.key），或
  ///         恢复路径 `handshake <H> <C> <b64恢复码> <b64"rec">`（5 字段）。
  /// 缺凭据（m1/m2a 未传令牌）→ 抛 [VaultException]（清晰失败，不空握）。
  static String _handshakeLine(String? mode, String h, String c,
      {String? password, String? recoveryCode}) {
    String? b64pw;
    if (password != null && password.isNotEmpty) {
      b64pw = base64Encode(utf8.encode(password));
    }
    switch (mode) {
      case 'm1':
        if (b64pw == null) throw VaultException('m1 vault 解锁需要口令');
        return 'handshake $h $c $b64pw\n';
      case 'm2a':
        if (recoveryCode != null && recoveryCode.isNotEmpty) {
          final code = base64Encode(utf8.encode(recoveryCode));
          final label = base64Encode(utf8.encode('rec'));
          return 'handshake $h $c $code $label\n';
        }
        if (b64pw == null) {
          throw VaultException('m2a vault 解锁需要口令或恢复码');
        }
        return 'handshake $h $c $b64pw\n';
      default:
        // crypto（'C'）/ m2b：免密 3 字段（m2b 设备因子为 device.key）
        return 'handshake $h $c\n';
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

/// vault 子进程 stderr 行的级别推断（无结构化级别，按关键字粗分）：
/// vault 作为独立进程无法共享进程内 sink，故由 Dart 侧转发并并入统一日志。
LogLevel _vaultStderrLevel(String line) {
  final l = line.toLowerCase();
  if (l.contains('error') ||
      l.contains('fail') ||
      line.contains('错误') ||
      line.contains('失败') ||
      line.contains('异常')) {
    return LogLevel.error;
  }
  if (l.contains('warn') || line.contains('警告')) return LogLevel.warn;
  return LogLevel.debug;
}
