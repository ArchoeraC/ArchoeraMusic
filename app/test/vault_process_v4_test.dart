// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/security/vault_process.dart';
import 'package:archoera_music/services/security/vault_switch_snapshot.dart';

/// vault 会话（credential-vault-plan §3.7/§3.8）端到端测试（真实二进制）：
///   1. crypto/file 正常会话：set/get 中文往返 + 正常收尾 marker=ok
///   2. 'S' slots（m1/m2a/m2b）：init + 握手 set/get 往返 + 恢复码解锁
///   3. 锚点不一致（vault.auth 被替换）→ 拒绝服务（VaultException）
///   4. 信号终止可被父进程感知（§3.7 前提）+ crash 标记契约（写→消费→删除）
///   5. v4 后端指纹不配对 → serve 报 SHARE_BACKEND_MISMATCH（明确错误码）
///
/// 运行前提（headless 无 Secret Service 时）：
///   ARCHOERA_VAULT_BIN=core/vault-rs/build/archoera-vault-test
///   ARCHOERA_VAULT_BACKEND=file
///   （指向测试构建 + 选择生产 FileStore 文件密钥后端；先跑
///   core/vault-rs/build-test.sh。SEC-19 后不再有测试明文存储后门）。
///   crash 用例建议 ARCHOERA_VAULT_NO_ABORT=1（否则 fail-closed 会终止测试进程）。
void main() {
  // 退出码 → 标记契约（纯函数，无需 vault 二进制）：这里固化「沙箱被蓄意破坏（87）
  // 与信号终止同等致命」——vault 侧检测到可观测的蓄意破坏即自毁退出 87，
  // 本层据此写 crash 标记并 exit(86) 连带主程序退出；而解锁失败等「主动报错退出」
  // 仍只记 fail（不联动，避免攻击者用坏文件逼应用自杀）。
  test('退出码→标记：87 = 沙箱被破坏（致命）；1 = 主动报错（不联动）', () {
    expect(VaultProcess.sandboxBreachExit, 87, reason: '须与 vault guard 侧常量对齐');
    expect(VaultProcess.markerForExit(0, normal: true), 'ok');
    expect(VaultProcess.markerForExit(1, normal: true), 'fail');
    expect(VaultProcess.markerForExit(87, normal: true), 'crash');
    expect(VaultProcess.markerForExit(-1, normal: false), 'crash');
    expect(VaultProcess.markerForExit(0, normal: false), 'crash');
  });

  // 标记校验类用例要求 ARCHOERA_VAULT_BIN 指向 TEST 构建（见文件头运行前提）；
  // 未设置时 dev 兜底会解析到 PROD 二进制 → 标记断言必然失败，跳过（CI 会设）。
  final skipNoTestBin = Platform.environment['ARCHOERA_VAULT_BIN'] == null
      ? '需要 ARCHOERA_VAULT_BIN 指向测试构建（见文件头运行前提）'
      : null;

  Future<Directory> makeTmp(String prefix) async {
    final tmp = await Directory.systemTemp.createTemp(prefix);
    addTearDown(() => tmp.deleteSync(recursive: true));
    return tmp;
  }

  // 切换方案预检（`canInitCrypto`）：契约是「返回布尔、不抛、**不触碰数据目录**」。
  // 本机是否支持 LEGACY（系统钥匙串）因平台而异（Linux 无 Secret Service → false），
  // 故这里只断言契约与数据目录安全，不硬编码平台结论。
  // 需要真实 vault 二进制；未设置 ARCHOERA_VAULT_BIN 时用 dev 兜底解析（可能失败 → 跳过）。
  test('canInitCrypto：返回布尔且不触碰数据目录（预检不得破坏现有容器）', () async {
    if (!VaultProcess.available) {
      markTestSkipped('vault 二进制不可用，跳过');
      return;
    }
    final tmp = await makeTmp('vault_probe');
    final sentinel = File('${tmp.path}/credentials.vault');
    sentinel.writeAsStringSync('SENTINEL-CONTAINER', flush: true);
    final before = sentinel.readAsStringSync();

    final ok = await VaultProcess.canInitCrypto();

    expect(ok, isA<bool>(), reason: '预检必须给出布尔结论（不抛异常）');
    expect(sentinel.existsSync(), isTrue, reason: '预检不得删除现有容器');
    expect(sentinel.readAsStringSync(), before, reason: '预检不得改动现有容器内容');
    // 预检也不得在数据目录里留下锚点 / 标记 / 备份等痕迹
    for (final name in [
      'vault.auth',
      'vault.marker',
      'device.key',
      VaultSwitchSnapshot.dirName,
    ]) {
      expect(File('${tmp.path}/$name').existsSync(), isFalse, reason: '$name 不该出现');
    }
  });

  // 读取 'S'（slots）文件头首个口令槽的 Argon2id 参数（m/t/p，u32 小端）。
  // 布局：magic(4)+version(1)+vaultId(16)+createdAt(8)+alg(1)+slotCount(1)
  //       +slot[0].kind(1) → m@32 / t@36 / p@40。
  int u32(List<int> b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  ({int m, int t, int p}) slotKdf(File f) {
    final b = f.readAsBytesSync();
    expect(b[4], 'S'.codeUnitAt(0), reason: '应为 slots（S）模式文件头');
    return (m: u32(b, 32), t: u32(b, 36), p: u32(b, 40));
  }

  test('crypto/file 正常会话：set/get 中文往返 + marker=ok', () async {
    final tmp = await makeTmp('vault_v4_normal');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }

    final anchor = await VaultProcess.initFile(tmp.path);
    expect(anchor.isNotEmpty, isTrue, reason: 'init-file 应返回会话锚点');
    expect(await VaultProcess.mode(tmp.path), 'crypto');

    await VaultProcess.set(tmp.path, 'kugou:session', 'S3cr3t-中文');
    // get 返回 base64 载荷（调用方解码，如 vault_session_store）
    expect(await VaultProcess.get(tmp.path, 'kugou:session'),
        base64Encode(utf8.encode('S3cr3t-中文')));

    await VaultProcess.delete(tmp.path, 'kugou:session');
    expect(await VaultProcess.get(tmp.path, 'kugou:session'), isNull);

    // 正常会话收尾写 marker=ok：consumeCrashMarker 返回 false 并消费删除
    expect(VaultProcess.consumeCrashMarker(tmp.path), isFalse);
    expect(VaultProcess.consumeCrashMarker(tmp.path), isFalse,
        reason: '首次消费即删，重复读取无内容');
  });

  test('slots m1：init + 口令握手 set/get 往返 + 错误口令被拒', () async {
    final tmp = await makeTmp('vault_v4_m1');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }
    const pw = 'm1-口令-42';
    final anchor = await VaultProcess.initM1(tmp.path, pw);
    expect(anchor.isNotEmpty, isTrue, reason: 'init-m1 应返回会话锚点');
    expect(await VaultProcess.mode(tmp.path), 'm1');

    await VaultProcess.set(tmp.path, 'kugou:session', 'tok-m1', password: pw);
    expect(await VaultProcess.get(tmp.path, 'kugou:session', password: pw),
        base64Encode(utf8.encode('tok-m1')));

    // 错误口令 → 握手 GCM 认证失败被拒
    await expectLater(
      VaultProcess.get(tmp.path, 'kugou:session', password: 'wrong'),
      throwsA(isA<VaultException>()),
    );
  });

  test('slots m1：低预设 init 落盘 32768 + set-kdf 重封装不丢数据', () async {
    final tmp = await makeTmp('vault_v4_m1_kdf');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }
    const pw = 'kdf-口令-42';
    // 低预设 (32768, 3, 1)：文件头口令槽应记录该参数
    await VaultProcess.initM1(tmp.path, pw, kdfM: 32768, kdfT: 3, kdfP: 1);
    final vaultFile = File('${tmp.path}/credentials.vault');
    var kdf = slotKdf(vaultFile);
    expect(kdf.m, 32768, reason: '低预设应写入 m=32768');
    expect(kdf.t, 3);
    expect(kdf.p, 1);
    expect(await VaultProcess.kdf(tmp.path), (m: 32768, t: 3, p: 1),
        reason: 'status 应回显当前口令槽 KDF 强度');

    // 写入一条凭据，作为重封装「不丢数据」的观测点
    await VaultProcess.set(tmp.path, 'kugou:session', 'keep-me', password: pw);

    // set-kdf → 高预设 (262144, 4, 1)：仅重封装口令槽，K 与条目不变
    await VaultProcess.setKdf(tmp.path,
        m: 262144, t: 4, p: 1, password: pw);
    kdf = slotKdf(vaultFile);
    expect(kdf.m, 262144, reason: 'set-kdf 应改写口令槽 m');
    expect(kdf.t, 4);
    expect(kdf.p, 1);
    expect(await VaultProcess.kdf(tmp.path), (m: 262144, t: 4, p: 1));

    // 不丢数据：以新参数握手仍可回读原条目
    expect(await VaultProcess.get(tmp.path, 'kugou:session', password: pw),
        base64Encode(utf8.encode('keep-me')),
        reason: 'set-kdf 重封装不得丢失既有条目');
  });

  test('slots set-kdf：错误口令 SHARE_MISMATCH + crypto 模式明确拒绝', () async {
    final tmp = await makeTmp('vault_v4_kdf_err');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }
    // crypto（无口令 KDF）：set-kdf 应明确报「不支持」而非崩溃
    await VaultProcess.initFile(tmp.path);
    await expectLater(
      VaultProcess.setKdf(tmp.path, m: 32768, t: 3, p: 1),
      throwsA(isA<VaultException>()),
    );

    // m1 错误口令 → SHARE_MISMATCH（归类为 VaultShareMismatchException）。
    // 放最后：错误口令会触发锁定退避，不影响其它用例。
    final tmp2 = await makeTmp('vault_v4_kdf_err_m1');
    await VaultProcess.initM1(tmp2.path, 'right-pw');
    await expectLater(
      VaultProcess.setKdf(tmp2.path, m: 32768, t: 3, p: 1, password: 'wrong'),
      throwsA(isA<VaultShareMismatchException>()),
    );
  });

  test('slots m2a：init + 口令往返 + 恢复码解锁（device.key 缺失）', () async {
    final tmp = await makeTmp('vault_v4_m2a');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }
    const pw = 'm2a-口令-7';
    final res = await VaultProcess.initM2a(tmp.path, pw);
    expect(res.anchor.isNotEmpty, isTrue, reason: 'init-m2a 应返回会话锚点');
    expect(res.recoveryCode.isNotEmpty, isTrue, reason: 'init-m2a 应返回恢复码');
    expect(await VaultProcess.mode(tmp.path), 'm2a');

    await VaultProcess.set(tmp.path, 'kugou:session', 'tok-m2a', password: pw);
    expect(await VaultProcess.get(tmp.path, 'kugou:session', password: pw),
        base64Encode(utf8.encode('tok-m2a')));

    // 删除 device.key：口令路径 → NEED_RECOVERY；恢复码路径可解锁
    File('${tmp.path}/device.key').deleteSync();
    await expectLater(
      VaultProcess.get(tmp.path, 'kugou:session', password: pw),
      throwsA(isA<VaultNeedRecoveryException>()),
    );
    expect(
        await VaultProcess.get(tmp.path, 'kugou:session',
            recoveryCode: res.recoveryCode),
        base64Encode(utf8.encode('tok-m2a')));
  });

  test('slots m2b：init 本机免密 set/get 往返', () async {
    final tmp = await makeTmp('vault_v4_m2b');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }
    final anchor = await VaultProcess.initM2b(tmp.path);
    expect(anchor.isNotEmpty, isTrue, reason: 'init-m2b 应返回会话锚点');
    expect(await VaultProcess.mode(tmp.path), 'm2b');

    await VaultProcess.set(tmp.path, 'kugou:session', 'tok-m2b');
    expect(await VaultProcess.get(tmp.path, 'kugou:session'),
        base64Encode(utf8.encode('tok-m2b')));

    // 删除 device.key → 免密握手 NEED_RECOVERY
    File('${tmp.path}/device.key').deleteSync();
    await expectLater(
      VaultProcess.get(tmp.path, 'kugou:session'),
      throwsA(isA<VaultNeedRecoveryException>()),
    );
  });

  test('锚点不一致（vault.auth 被替换）→ 拒绝服务', () async {
    final tmp = await makeTmp('vault_v4_anchor');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }

    await VaultProcess.initFile(tmp.path);
    await VaultProcess.set(tmp.path, 'kugou:session', 'x');

    // 篡改本地锚点文件（模拟攻击者替换 vault.auth 后重新指向别的 vault）
    File('${tmp.path}/vault.auth')
        .writeAsStringSync(base64Encode(List<int>.filled(32, 0xAA)));

    await expectLater(
      VaultProcess.get(tmp.path, 'kugou:session'),
      throwsA(isA<VaultException>()
          .having((e) => e.message, 'message', contains('锚点'))),
      reason: '锚点不一致应拒绝服务（vault 文件可能被替换）',
    );
  });

  test('锚点文件被替换为符号链接 → 拒绝服务（且不阻塞）', () async {
    final tmp = await makeTmp('vault_v4_anchor_link');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }
    await VaultProcess.initFile(tmp.path);
    await VaultProcess.set(tmp.path, 'kugou:session', 'x');

    final auth = File('${tmp.path}/vault.auth');
    auth.deleteSync();
    Link(auth.path).createSync('/dev/zero'); // 非普通文件（FIFO 走同一类型判定）

    await expectLater(
      VaultProcess.get(tmp.path, 'kugou:session'),
      throwsA(isA<VaultException>()
          .having((e) => e.message, 'message', contains('锚点'))),
      reason: '锚点文件非普通文件应 fail-closed，且读取不得阻塞（FIFO/符号链接）',
    );
  });

  test('信号终止可被感知 + crash 标记契约', () async {
    final tmp = await makeTmp('vault_v4_crash');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }
    await VaultProcess.initFile(tmp.path);

    // 原始会话：握手成功后会话中被 SIGKILL → 父进程感知信号退出（非零）
    final rng = Random.secure();
    final p = await Process.start(VaultProcess.binary, ['serve', tmp.path]);
    final h = base64Encode(List<int>.generate(32, (_) => rng.nextInt(256)));
    final c = base64Encode(List<int>.generate(16, (_) => rng.nextInt(256)));
    p.stdin.write('handshake $h $c\n');
    await p.stdin.flush();
    final resp = await p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    expect(resp.startsWith('ok handshake'), isTrue, reason: '握手应成功');
    // 握手版本指纹：应答第 5 字段须为构建标记（env 信任边界下为 TEST；
    // 默认路径二进制要求 PROD——见 _VaultSession.open 校验）
    final parts = resp.split(' ');
    expect(parts.length, greaterThanOrEqualTo(5),
        reason: '握手应答应携带构建标记字段');
    expect(parts[4], startsWith('ARCHOERA-VAULT-TEST'),
        reason: '测试二进制握手应上报 TEST 构建标记');

    p.kill(ProcessSignal.sigkill);
    final code =
        await p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    expect(code, isNot(0), reason: '信号终止应产生非零退出码（§3.7 前提）');

    // crash 标记契约：父进程检测到异常退出后写 crash 标记，下次启动显著警告
    File('${tmp.path}/vault.marker').writeAsStringSync(VaultProcess.markerCrash);
    expect(VaultProcess.consumeCrashMarker(tmp.path), isTrue,
        reason: 'crash 标记应被消费');
    expect(VaultProcess.consumeCrashMarker(tmp.path), isFalse,
        reason: '消费后文件应删除');
  }, skip: skipNoTestBin);

  test('v4 后端指纹不配对 → serve 报 SHARE_BACKEND_MISMATCH（明确错误码）', () async {
    final tmp = await makeTmp('vault_v4_backend');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }

    // 文件密钥初始化（显式 FileStore）：v4 文件头记录 backend=file
    // （SEC-19 后 headless 唯一可用后端；insecure 后门已删除）。
    await VaultProcess.initFile(tmp.path);
    final vaultFile = File('${tmp.path}/credentials.vault');
    final original = vaultFile.readAsBytesSync();
    // 'C'（crypto）文件头布局：magic(0:4)+version(4)+reserved(5:8)
    //                     +K_vault(8:40)+backendLen(40)+backend(41:41+len)
    expect(original[4], 'C'.codeUnitAt(0), reason: "应为 crypto（'C'）模式文件头");
    final blen = original[40];
    expect(utf8.decode(original.sublist(41, 41 + blen)), 'file');

    // 就地改写文件头 backend 为等长异名（file → otth）：工厂按文件头分发，异名
    // 不再匹配 FileStore → 回落平台后端（libsecret），其指纹 ≠ 记录值 →
    // 明确错误码 SHARE_BACKEND_MISMATCH（此前为模糊的 GCM mismatch）。
    final tampered = List<int>.from(original);
    tampered.setRange(41, 41 + blen, utf8.encode('otth'));
    vaultFile.writeAsBytesSync(tampered);

    final rng = Random.secure();
    final h = base64Encode(List<int>.generate(32, (_) => rng.nextInt(256)));
    final c = base64Encode(List<int>.generate(16, (_) => rng.nextInt(256)));
    // 指纹校验在触碰存储之前完成；补一个非空 session bus 地址，防「无 D-Bus」
    // 在工厂构造期提前抛 SecretStoreUnavailable（免真实 keyring 依赖）。
    final backendMismatchEnv = <String, String>{
      ...Platform.environment,
    };
    if ((backendMismatchEnv['DBUS_SESSION_BUS_ADDRESS'] ?? '').isEmpty) {
      backendMismatchEnv['DBUS_SESSION_BUS_ADDRESS'] =
          'unix:path=/nonexistent/archoera-vault-test';
    }
    final p = await Process.start(VaultProcess.binary, ['serve', tmp.path],
        environment: backendMismatchEnv);
    p.stdin.write('handshake $h $c\n');
    await p.stdin.flush();
    final resp = await p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    expect(resp, startsWith('err SHARE_BACKEND_MISMATCH'),
        reason: '记录后端与实际后端不配对应报明确错误码，而非模糊 GCM mismatch');
    p.stdin.close();
    await p.exitCode.timeout(const Duration(seconds: 5));

    // 还原文件头 backend → 配对恢复，正常解锁（校验只拦截不配对，不破坏配对会话）
    vaultFile.writeAsBytesSync(original);
    final p2 = await Process.start(VaultProcess.binary, ['serve', tmp.path]);
    p2.stdin.write('handshake $h $c\n');
    await p2.stdin.flush();
    final resp2 = await p2.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    expect(resp2, startsWith('ok handshake'), reason: '配对后端应解锁');
    p2.stdin.close();
    await p2.exitCode.timeout(const Duration(seconds: 5));
  }, skip: skipNoTestBin);
}
