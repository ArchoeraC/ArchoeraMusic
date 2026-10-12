// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 原生库完整性校验（SEC-08）：构建期生成 SHA-256 清单，运行期在
/// `DynamicLibrary.open` 前比对摘要。
///
/// 清单 `ARCHOERA-NATIVE-MANIFEST.txt` 与库文件同目录（bundle 的 `native/`），
/// 每行 `<64-hex-sha256>  <basename>`（两个空格分隔）；`#` 注释行与空行忽略，
/// 键为**文件名基**（库与其清单同目录）。
///
/// 防篡改签名：清单可附带分离签名 `ARCHOERA-NATIVE-MANIFEST.sig1`（key1
/// ECDSA P-256/SHA-256，DER，覆盖清单原文）。存在签名时**先验签、再比对摘要**
/// ——纯摘要清单可被攻击者连同库一起替换并重算，签名使其无法伪造（fail-closed）。
/// 验签用二进制内嵌官方公钥（[archoeraWatermarkPubKeyHex]，见 `app/watermark.dart`）。
///
/// 定位**只锚定可执行文件祖先链**（及 dev cwd 兜底），绝不读取
/// `ARCHOERA_NATIVE_DIR` 等环境变量——避免攻击者用环境变量把校验指向伪造清单。
///
/// 语义：
/// - 打包态（找到清单）**fail-closed**：签名存在但不合法 / 文件缺失 / 摘要不符 /
///   未登记 → 抛 [StateError]，调用方不得打开该库；
/// - 无签名（仅摘要）回退为 hash-only，仅首次 [Log.w] 提示一次（过渡兼容）；
/// - 开发态（无清单）跳过校验，仅首次 [Log.w] 提示一次（保证 `flutter run`
///   与测试可用）。清单缺失本身**绝不**抛异常。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../app/watermark.dart';
import 'log/log.dart';
import 'native_lib_paths.dart';

class NativeIntegrity {
  NativeIntegrity._();

  /// 清单文件名（与 `native/` 库同目录）。
  static const String manifestName = 'ARCHOERA-NATIVE-MANIFEST.txt';

  /// 清单分离签名文件名（与清单同目录；key1 ECDSA P-256/SHA-256，DER）。
  static const String manifestSignatureName = 'ARCHOERA-NATIVE-MANIFEST.sig1';

  /// 测试接缝：仅测试置真，生产恒为 false。
  ///
  /// 置真后才读取 [debugBundleRoot] 或环境变量 `ARCHOERA_TEST_BUNDLE_ROOT`
  /// 作为 bundle 根，避免生产进程被该环境变量劫持来指向伪造清单。
  static bool debugTestMode = false;

  /// 测试接缝：显式覆盖 bundle 根（优先于环境变量）。仅 [debugTestMode]
  /// 为真时生效；应指向包含 `native/` 子目录的临时目录。
  static String? debugBundleRoot;

  /// 测试接缝：覆盖验签公钥（未压缩 `04||X||Y` 十六进制）。仅 [debugTestMode]
  /// 为真时生效——生产始终使用二进制内嵌官方公钥（[archoeraWatermarkPubKeyHex]）。
  static String? debugPublicKeyHex;

  static const String _testBundleRootEnv = 'ARCHOERA_TEST_BUNDLE_ROOT';

  static bool _located = false;
  static String? _manifestPath;
  static Map<String, String>? _entries;
  static bool _warnedDisabled = false;
  static bool _signaturePresent = false;
  static bool _signatureValid = false;
  static bool _warnedUnsigned = false;

  /// 是否找到并加载了完整性清单（打包态为 true）。
  static bool get manifestPresent {
    _locate();
    return _manifestPath != null;
  }

  /// 校验单个库文件；无清单时跳过（dev），否则摘要不符即抛 [StateError]。
  ///
  /// 清单附带分离签名时，**先验签**（fail-closed）再比对摘要——签名不合法
  /// 立即抛错，绝不进入摘要比对（否则篡改清单 + 重算摘要可绕过）。
  static void verifyOrThrow(String path) {
    final entries = _locate();
    if (entries == null) {
      _warnDisabledOnce();
      return;
    }
    if (_signaturePresent && !_signatureValid) {
      throw StateError('原生完整性清单签名校验失败（可能被篡改）');
    }
    if (!_signaturePresent) {
      _warnUnsignedOnce();
    }
    final expected = entries[_basename(path)];
    String actual;
    try {
      actual = sha256.convert(File(path).readAsBytesSync()).toString();
    } catch (err) {
      throw StateError('原生库完整性校验失败：$path（无法读取：$err）');
    }
    if (expected == null || expected != actual) {
      throw StateError('原生库完整性校验失败：$path（manifest 不匹配）');
    }
  }

  /// [verifyOrThrow] 的模块化别名（调用点可携带模块语义，便于诊断）。
  static void verifyModule(NativeModule m, String path) {
    verifyOrThrow(path);
  }

  /// 清空定位/解析缓存（测试用）。不重置 [debugTestMode]/[debugBundleRoot]，
  /// 以便测试先设接缝再调用。
  static void resetForTest() {
    _located = false;
    _manifestPath = null;
    _entries = null;
    _warnedDisabled = false;
    _signaturePresent = false;
    _signatureValid = false;
    _warnedUnsigned = false;
  }

  static Map<String, String>? _locate() {
    if (_located) return _entries;
    _located = true;
    final file = _findManifest();
    if (file == null) return null;
    _manifestPath = file.absolute.path;
    final text = file.readAsStringSync();
    _entries = _parse(text);
    _checkSignature(file, text);
    return _entries;
  }

  /// 校验清单分离签名（若存在）。签名覆盖清单原文；[debugTestMode] 下可用
  /// [debugPublicKeyHex] 注入测试密钥，生产一律使用内嵌官方公钥。任何解析/
  /// 读取异常 → 视为签名不合法（fail-closed）。
  static void _checkSignature(File manifest, String text) {
    final sig = File('${manifest.parent.path}/$manifestSignatureName');
    if (!sig.existsSync()) {
      _signaturePresent = false;
      _signatureValid = false;
      return;
    }
    _signaturePresent = true;
    try {
      final bytes = sig.readAsBytesSync();
      final key = debugTestMode ? debugPublicKeyHex : null;
      // key 非空仅出现在 debugTestMode（测试接缝）；生产恒用内嵌官方公钥分支。
      _signatureValid = key != null
          // ignore: invalid_use_of_visible_for_testing_member
          ? verifyArchoeraSignedBytesWithKey(text, bytes, key)
          : verifyArchoeraSignedBytes(text, bytes);
    } catch (_) {
      _signatureValid = false;
    }
  }

  static File? _findManifest() {
    if (debugTestMode) {
      final override =
          debugBundleRoot ?? Platform.environment[_testBundleRootEnv];
      if (override != null && override.isNotEmpty) {
        final f = File('$override/native/$manifestName');
        return f.existsSync() ? f : null;
      }
    }
    // 打包态：从可执行文件祖先链逐级查找 <dir>/native/。
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 8; i++) {
      final cand = File('${dir.path}/native/$manifestName');
      if (cand.existsSync()) return cand;
      dir = dir.parent;
    }
    // dev 兜底：flutter run / 测试时 cwd。
    final dev = File('${Directory.current.path}/native/$manifestName');
    return dev.existsSync() ? dev : null;
  }

  static Map<String, String> _parse(String content) {
    final entries = <String, String>{};
    for (final raw in const LineSplitter().convert(content)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final sep = line.indexOf('  ');
      if (sep <= 0) continue;
      final hash = line.substring(0, sep).trim().toLowerCase();
      final name = line.substring(sep + 2).trim();
      if (name.isEmpty || hash.length != 64) continue;
      entries[name] = hash;
    }
    return entries;
  }

  static String _basename(String path) {
    final slash = path.lastIndexOf('/');
    final back = path.lastIndexOf('\\');
    final at = slash > back ? slash : back;
    return at < 0 ? path : path.substring(at + 1);
  }

  static void _warnDisabledOnce() {
    if (_warnedDisabled) return;
    _warnedDisabled = true;
    Log.w('ffi', '未找到 $manifestName，开发态跳过原生库完整性校验（SEC-08）');
  }

  static void _warnUnsignedOnce() {
    if (_warnedUnsigned) return;
    _warnedUnsigned = true;
    Log.w('ffi',
        '完整性清单缺少 $manifestSignatureName 签名，回退为仅摘要校验（SEC-08）');
  }
}
