import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/security/vault_process.dart';

/// vault-4（credential-vault-plan §3.7/§3.8）端到端测试（真实二进制）：
///   1. 正常会话：set/get 中文往返 + 正常收尾 marker=ok（consumeCrashMarker 消费后 false）
///   2. 锚点不一致（vault.auth 被替换）→ 拒绝服务（VaultException）
///   3. 信号终止可被父进程感知（§3.7 前提）+ crash 标记契约（写→消费→删除）
///
/// 运行前提（headless 无 Secret Service 时）：
///   ARCHOERA_VAULT_BIN=core/vault/build/archoera-vault-test
///   ARCHOERA_VAULT_INSECURE_FILE_STORE=1
///   （指向测试构建 + 显式启用其明文存储；先跑 core/vault/build-test.sh）。
///   crash 用例建议 ARCHOERA_VAULT_NO_ABORT=1（否则 fail-closed 会终止测试进程）。
void main() {
  test('正常会话：set/get 中文往返 + marker=ok', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_v4_normal');
    addTearDown(() => tmp.deleteSync(recursive: true));
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }

    final anchor = await VaultProcess.init(tmp.path);
    expect(anchor.isNotEmpty, isTrue, reason: 'init 应返回会话锚点');

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

  test('锚点不一致（vault.auth 被替换）→ 拒绝服务', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_v4_anchor');
    addTearDown(() => tmp.deleteSync(recursive: true));
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }

    await VaultProcess.init(tmp.path);
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

  test('信号终止可被感知 + crash 标记契约', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_v4_crash');
    addTearDown(() => tmp.deleteSync(recursive: true));
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }
    await VaultProcess.init(tmp.path);

    // 原始会话：握手成功后会话中被 SIGKILL → 父进程感知信号退出（非零）
    final rng = Random.secure();
    final p = await Process.start(VaultProcess.binary, ['serve', tmp.path],
        environment: {
          ...Platform.environment,
          VaultProcess.envParentOk: 'flutter_tester,dart',
        });
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
  });
}
