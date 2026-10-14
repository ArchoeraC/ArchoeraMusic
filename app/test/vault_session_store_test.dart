// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/security/vault_process.dart';
import 'package:archoera_music/services/streaming/streaming_store.dart';
import 'package:archoera_music/services/streaming/streaming_types.dart';
import 'package:archoera_music/stores/vault_session_store.dart';

/// vault 会话存储端到端冒烟测试（对真实 `archoera-vault` NativeAOT 二进制）：
///   1. save → 落盘 → 重建 store 回读一致（写穿缓存 + 串行持久化）
///   2. clear → vault 条目删除 → 重建后为空
///   3. 旧明文 `netease_session.json` 首启迁移进 vault 并删除明文文件
///   4. destroy 后 vault 文件消失（密文不可恢复）
///   5. 'S' slots：m1（口令）/ m2a（口令 + 恢复码）/ m2b（本机免密）解锁 + 往返
///
/// 运行前提（headless 无 Secret Service 时）：
///   ARCHOERA_VAULT_BIN=core/vault-rs/build/archoera-vault-test
///   ARCHOERA_VAULT_BACKEND=file
///   （指向测试构建 + 选择生产 FileStore 文件密钥后端；先跑 core/vault-rs/build-test.sh。
///   生产二进制与测试构建存储行为一致、仅构建标记不同，VaultProcess 默认路径校验
///   PROD 标记，测试二进制只能经显式 ARCHOERA_VAULT_BIN 供测试/CI 使用。
///   SEC-19 后不再有测试明文存储后门。）
/// 二进制经 dev 兜底解析：cwd=app/ → app/core/vault-rs/build/archoera-vault。
void main() {
  // 测试二进制标记校验需要 ARCHOERA_VAULT_BIN 指向 TEST 构建（见文件头运行前提）；
  // 未设置时 dev 兜底会解析到 PROD 二进制 → 标记断言必然失败，跳过该用例（CI 会设）。
  final skipNoTestBin = Platform.environment['ARCHOERA_VAULT_BIN'] == null
      ? '需要 ARCHOERA_VAULT_BIN 指向测试构建（见文件头运行前提）'
      : null;

  final skipNoVault = Platform.environment['ARCHOERA_VAULT_BIN'] == null
      ? '需要 ARCHOERA_VAULT_BIN 指向测试构建'
      : null;

  Future<Directory> makeTmp(String prefix) async {
    final tmp = await Directory.systemTemp.createTemp(prefix);
    addTearDown(() => tmp.deleteSync(recursive: true));
    return tmp;
  }

  test('save/clear 持久化 + 重建回读一致', () async {
    final tmp = await makeTmp('vault_store_test');

    final store = VaultSessionStore(dataDir: tmp.path);
    await store.initialize();
    if (!store.vaultAvailable) {
      markTestSkipped('vault 不可用（缺二进制或 OS 安全存储），跳过持久化断言');
      return;
    }

    store.save('kugou', {'token': 'tok-1', 'userid': '42'});
    store.save('netease', {'MUSIC_U': 'cookie-x'});
    await store.flush();

    // 重建 store（模拟重启）：从 vault 解密加载
    final reloaded = VaultSessionStore(dataDir: tmp.path);
    await reloaded.initialize();
    expect(reloaded.get('kugou'), {'token': 'tok-1', 'userid': '42'});
    expect(reloaded.get('netease'), {'MUSIC_U': 'cookie-x'});

    // 磁盘无明文（credentials.vault 与份额文件均不含明文串）
    final files = tmp.listSync(recursive: true).whereType<File>();
    for (final f in files) {
      final bytes = f.readAsBytesSync();
      final text = utf8.decode(bytes, allowMalformed: true);
      expect(text.contains('tok-1'), isFalse,
          reason: '${f.path} 不应含明文');
      expect(text.contains('cookie-x'), isFalse,
          reason: '${f.path} 不应含明文');
    }

    // clear → 条目删除
    store.clear('kugou');
    await store.flush();
    final reloaded2 = VaultSessionStore(dataDir: tmp.path);
    await reloaded2.initialize();
    expect(reloaded2.get('kugou'), isEmpty);
    expect(reloaded2.get('netease'), {'MUSIC_U': 'cookie-x'});
  });

  test('crypto 方案（LEGACY）：默认惰性 init-crypto → 模式 crypto + 往返回读 + 无明文', () async {
    final tmp = await makeTmp('vault_crypto_store');

    // 默认 defaultScheme='crypto'（推荐稳定）：未初始化库惰性走 init-crypto
    final store = VaultSessionStore(dataDir: tmp.path);
    await store.initialize();
    if (!store.vaultAvailable) {
      markTestSkipped('vault 不可用，跳过持久化断言');
      return;
    }
    expect(store.mode, 'crypto', reason: '默认偏好应初始化 LEGACY crypto 方案');

    store.save('kugou', {'token': 'crypto-tok'});
    store.save('netease', {'MUSIC_U': 'crypto-cookie'});
    await store.flush();

    // 重建 store（模拟重启）：模式保持 crypto，数据回读一致
    final reloaded = VaultSessionStore(dataDir: tmp.path);
    await reloaded.initialize();
    expect(reloaded.mode, 'crypto');
    expect(reloaded.get('kugou'), {'token': 'crypto-tok'});
    expect(reloaded.get('netease'), {'MUSIC_U': 'crypto-cookie'});

    // 磁盘无明文（vault 文件与份额文件均不含明文串）
    for (final f in tmp.listSync(recursive: true).whereType<File>()) {
      final text = utf8.decode(f.readAsBytesSync(), allowMalformed: true);
      expect(text.contains('crypto-tok'), isFalse,
          reason: '${f.path} 不应含明文');
      expect(text.contains('crypto-cookie'), isFalse,
          reason: '${f.path} 不应含明文');
    }
  });

  test('m2a 方案 + 库缺失：不静默降级为 crypto，等待显式初始化', () async {
    final tmp = await makeTmp('vault_m2a_missing');
    final store = VaultSessionStore(dataDir: tmp.path, defaultScheme: 'm2a');
    await store.initialize();
    if (!store.vaultAvailable) {
      markTestSkipped('vault 不可用，跳过');
      return;
    }
    // 关键：绝不 auto-init 成单因子 crypto（安全降级 + pref/容器不一致）
    expect(File('${tmp.path}/credentials.vault').existsSync(), isFalse,
        reason: 'm2a 需要用户因子，库缺失时不得自动初始化任何容器');
    expect(store.mode, isNull, reason: '应保持未初始化，交由 UI 初始化门');
    expect(store.needsPassword, isTrue,
        reason: '应提示需要口令（用户显式初始化/解锁），而非静默建库');
  }, skip: skipNoVault);

  test('file 方案：defaultScheme=file 惰性 init-file → mode crypto + backend file + 往返', () async {
    final tmp = await makeTmp('vault_file_store');

    final store = VaultSessionStore(dataDir: tmp.path, defaultScheme: 'file');
    await store.initialize();
    if (!store.vaultAvailable) {
      markTestSkipped('vault 不可用，跳过持久化断言');
      return;
    }
    expect(store.mode, 'crypto');
    expect(await VaultProcess.backend(tmp.path), 'file',
        reason: 'file 方案后端指纹应为 file');

    store.save('kugou', {'token': 'file-tok'});
    await store.flush();
    final reloaded = VaultSessionStore(dataDir: tmp.path, defaultScheme: 'file');
    await reloaded.initialize();
    expect(reloaded.get('kugou'), {'token': 'file-tok'});
  });

  test('旧明文 netease_session.json 首启迁移并删除', () async {
    final tmp = await makeTmp('vault_migrate_test');

    // 预置旧明文文件（旧 FileSessionStore 格式：platform → cookies）
    final legacy = File('${tmp.path}/netease_session.json');
    legacy.writeAsStringSync(jsonEncode({
      'kugou': {'token': 'legacy-token', 'userid': '7'},
      'netease': {'MUSIC_U': 'legacy-cookie'},
    }));

    final store = VaultSessionStore(dataDir: tmp.path);
    await store.initialize();
    if (!store.vaultAvailable) {
      markTestSkipped('vault 不可用，跳过迁移断言');
      return;
    }

    // 迁移后：内存可见 + 明文文件已删 + 重建仍可回读（已入 vault）
    expect(store.get('kugou'), {'token': 'legacy-token', 'userid': '7'});
    expect(store.get('netease'), {'MUSIC_U': 'legacy-cookie'});
    expect(legacy.existsSync(), isFalse, reason: '迁移成功应删除旧明文文件');

    final reloaded = VaultSessionStore(dataDir: tmp.path);
    await reloaded.initialize();
    expect(reloaded.get('kugou'), {'token': 'legacy-token', 'userid': '7'});
    expect(reloaded.get('netease'), {'MUSIC_U': 'legacy-cookie'});
  });

  test('destroy 后 vault 文件消失（密文不可恢复）', () async {
    final tmp = await makeTmp('vault_destroy_test');

    final store = VaultSessionStore(dataDir: tmp.path);
    await store.initialize();
    if (!store.vaultAvailable) {
      markTestSkipped('vault 不可用，跳过销毁断言');
      return;
    }
    store.save('kugou', {'token': 't', 'userid': '1'});
    await store.flush();
    final vaultFile = File('${tmp.path}/credentials.vault');
    expect(vaultFile.existsSync(), isTrue);

    // 全量销毁（安全设置页「清除会话」同一链路：删授权侧份额 + vault 文件）
    VaultProcess.destroy(tmp.path);
    expect(vaultFile.existsSync(), isFalse, reason: 'destroy 应删除 vault 文件');

    // destroy 后重建 store：无会话可加载
    final reloaded = VaultSessionStore(dataDir: tmp.path);
    await reloaded.initialize();
    expect(reloaded.get('kugou'), isEmpty);
  });

  test('slots m1：initM1 + 口令解锁 + 回读 + 错误口令被拒', () async {
    final tmp = await makeTmp('vault_m1_store');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过 m1 断言');
      return;
    }

    const pw = '会话-口令-42';
    await VaultProcess.initM1(tmp.path, pw);
    // 注意：Store 读取的 uid 带 `session:` 前缀（VaultSessionStore._uidFor）
    await VaultProcess.set(
        tmp.path, 'session:kugou', jsonEncode({'token': 'tok-m1s'}),
        password: pw);

    // 重建 store（模拟重启）：m1 未解锁 → needsPassword（不静默降级）
    final store = VaultSessionStore(dataDir: tmp.path);
    await store.initialize();
    expect(store.mode, 'm1');
    expect(store.needsPassword, isTrue,
        reason: 'm1 未解锁应置 needsPassword');
    expect(store.vaultAvailable, isFalse);
    expect(store.get('kugou'), isEmpty);

    // 正确口令 → 解锁成功，数据从 vault 回读
    expect(await store.unlockWithPassword(pw), isTrue);
    expect(store.needsPassword, isFalse);
    expect(store.vaultAvailable, isTrue);
    expect(store.get('kugou'), {'token': 'tok-m1s'});

    // 解锁后持久化带口令：清空落盘 → 重建后解锁回读为空
    store.clear('kugou');
    await store.flush();
    final reloaded = VaultSessionStore(dataDir: tmp.path);
    await reloaded.initialize();
    expect(reloaded.needsPassword, isTrue);
    expect(await reloaded.unlockWithPassword(pw), isTrue);
    expect(reloaded.get('kugou'), isEmpty);

    // 错误口令 → 解锁失败，保持 needsPassword（最后：触发退避不影响后续）
    expect(await reloaded.unlockWithPassword('wrong'), isFalse);
    expect(reloaded.needsPassword, isTrue);
  });

  test('slots m2a：口令解锁 + device.key 丢失后恢复码解锁 + 恢复后持久化', () async {
    final tmp = await makeTmp('vault_m2a_store');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过 m2a 断言');
      return;
    }

    const pw = 'm2a-会话-7';
    final res = await VaultProcess.initM2a(tmp.path, pw);
    expect(res.recoveryCode, isNotEmpty);
    await VaultProcess.set(
        tmp.path, 'session:kugou', jsonEncode({'token': 'tok-m2a'}),
        password: pw);

    // 口令路径解锁
    final store = VaultSessionStore(dataDir: tmp.path);
    await store.initialize();
    expect(store.mode, 'm2a');
    expect(store.needsPassword, isTrue);
    expect(await store.unlockWithPassword(pw), isTrue);
    expect(store.get('kugou'), {'token': 'tok-m2a'});

    // 删除 device.key：口令路径转 NEED_RECOVERY（不误报解锁成功）
    File('${tmp.path}/device.key').deleteSync();
    final broken = VaultSessionStore(dataDir: tmp.path);
    await broken.initialize();
    expect(await broken.unlockWithPassword(pw), isFalse);
    expect(broken.needsRecovery, isTrue,
        reason: 'device.key 丢失应置 needsRecovery');

    // 恢复码解锁 → 数据回读；恢复后持久化随恢复码落库
    expect(await broken.recover(res.recoveryCode), isTrue);
    expect(broken.needsRecovery, isFalse);
    expect(broken.get('kugou'), {'token': 'tok-m2a'});
    broken.save('kugou', {'token': 'tok-m2a-2'});
    await broken.flush();

    final re = VaultSessionStore(dataDir: tmp.path);
    await re.initialize();
    expect(await re.recover(res.recoveryCode), isTrue);
    expect(re.get('kugou'), {'token': 'tok-m2a-2'});
  });

  test('slots m2b：initM2b 本机免密加载 + 持久化往返', () async {
    final tmp = await makeTmp('vault_m2b_store');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过 m2b 断言');
      return;
    }

    await VaultProcess.initM2b(tmp.path);
    await VaultProcess.set(
        tmp.path, 'session:kugou', jsonEncode({'token': 'tok-m2b'}));

    final store = VaultSessionStore(dataDir: tmp.path);
    await store.initialize();
    expect(store.mode, 'm2b');
    expect(store.needsPassword, isFalse);
    expect(store.vaultAvailable, isTrue);
    expect(store.get('kugou'), {'token': 'tok-m2b'});

    store.save('netease', {'MUSIC_U': 'm2b-cookie'});
    await store.flush();
    final reloaded = VaultSessionStore(dataDir: tmp.path);
    await reloaded.initialize();
    expect(reloaded.get('netease'), {'MUSIC_U': 'm2b-cookie'});
  });

  test('StreamingStore m1：preload 置 needsPassword，解锁后凭据回读', () async {
    final tmp = await makeTmp('vault_ss_m1');
    addTearDown(StreamingStore.resetForTest);

    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过流媒体 m1 断言');
      return;
    }

    const pw = '流媒体-口令-7';
    await VaultProcess.initM1(tmp.path, pw);

    // 先解锁再保存：凭据带会话口令入 vault
    StreamingStore.resetForTest();
    StreamingStore.dataDirOverride = tmp.path;
    expect(await StreamingStore.unlockWithPassword(pw), isTrue);
    expect(StreamingStore.needsPassword, isFalse);
    StreamingStore.save([
      StreamingServerConfig(
        id: 'srv1',
        name: 'Demo',
        type: StreamingServerType.subsonic,
        host: '192.168.1.2',
        username: 'alice',
        password: 'pw-x',
      ),
    ], 'srv1');
    await StreamingStore.flush();

    // 模拟重启（内存态清空）：m1 未解锁 → needsPassword
    StreamingStore.resetForTest();
    StreamingStore.dataDirOverride = tmp.path;
    await StreamingStore.preloadSecrets();
    expect(StreamingStore.needsPassword, isTrue,
        reason: 'm1 未解锁 preload 应置 needsPassword');

    // 正确口令解锁：解锁本身不批量解密（SEC-03），凭据经 loadSecret 惰性回读
    expect(await StreamingStore.unlockWithPassword(pw), isTrue);
    expect(StreamingStore.needsPassword, isFalse);
    expect(StreamingStore.load().servers.first.password, isEmpty,
        reason: 'unlock 不得批量解密');
    await StreamingStore.loadSecret('srv1');
    final loaded = StreamingStore.load().servers.first;
    expect(loaded.password, 'pw-x');

    // 错误口令 → 解锁失败，保持 needsPassword（最后：触发退避不影响后续）
    StreamingStore.resetForTest();
    StreamingStore.dataDirOverride = tmp.path;
    await StreamingStore.preloadSecrets();
    expect(await StreamingStore.unlockWithPassword('wrong'), isFalse,
        reason: '错误口令不得误报解锁成功');
    expect(StreamingStore.needsPassword, isTrue);
  });

  test('未初始化：mode() 返回 null（方案由 prefs 兜底，默认 crypto）', () async {
    final tmp = await makeTmp('vault_mode_uninit');
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过未初始化断言');
      return;
    }
    expect(await VaultProcess.isInitialized(tmp.path), isFalse);
    // 未登录/全新数据目录：vault 尚未初始化，模式为 null（不虚构默认），
    // 具体加密方案由 prefs 偏好（默认 crypto）兜底展示
    expect(await VaultProcess.mode(tmp.path), isNull);
  });

  test('测试二进制标记校验：TEST 标记且非 PROD（条件编译与生产校验语义）', () async {
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过');
      return;
    }
    final bin = VaultProcess.binary; // ARCHOERA_VAULT_BIN 指向测试二进制
    final r = await Process.run(bin, ['--version']);
    expect(r.exitCode, 0);
    final out = r.stdout as String;
    // 测试构建须为 TEST 标记；生产标记校验（contains PROD）据此拒绝测试二进制
    expect(out, contains('ARCHOERA-VAULT-TEST'));
    expect(out, isNot(contains('ARCHOERA-VAULT-PROD')));
  }, skip: skipNoTestBin);
}
