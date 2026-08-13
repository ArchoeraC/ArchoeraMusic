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
///
/// 运行前提（headless 无 Secret Service 时）：
///   ARCHOERA_VAULT_BIN=core/vault/build/archoera-vault-test
///   ARCHOERA_VAULT_INSECURE_FILE_STORE=1
///   （指向测试构建 + 显式启用其明文存储；先跑 core/vault/build-test.sh。
///   生产二进制无明文存储分支，VaultProcess 默认路径校验 PROD 标记，
///   测试二进制只能经显式 ARCHOERA_VAULT_BIN 供测试/CI 使用。）
/// 二进制经 dev 兜底解析：cwd=app/ → app/core/vault/build/archoera-vault。
void main() {
  test('save/clear 持久化 + 重建回读一致', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_store_test');
    addTearDown(() => tmp.deleteSync(recursive: true));

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
    final tmp = await Directory.systemTemp.createTemp('vault_crypto_store');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // 默认 defaultScheme='crypto'（推荐稳定）：未初始化库惰性走 init-crypto
    final store = VaultSessionStore(dataDir: tmp.path);
    await store.initialize();
    expect(store.mode, 'crypto', reason: '默认偏好应初始化 LEGACY crypto 方案');
    expect(store.vaultAvailable, isTrue);

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

  test('旧明文 netease_session.json 首启迁移并删除', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_migrate_test');
    addTearDown(() => tmp.deleteSync(recursive: true));

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
    final tmp = await Directory.systemTemp.createTemp('vault_destroy_test');
    addTearDown(() => tmp.deleteSync(recursive: true));

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

    // 全量销毁（安全设置页「清除会话」同一链路：删 OS 份额 + vault 文件）
    VaultProcess.destroy(tmp.path);
    expect(vaultFile.existsSync(), isFalse, reason: 'destroy 应删除 vault 文件');

    // destroy 后重建 store：无会话可加载
    final reloaded = VaultSessionStore(dataDir: tmp.path);
    await reloaded.initialize();
    expect(reloaded.get('kugou'), isEmpty);
  });

  test('口令模式：initPassword + 口令握手 set/get + 错误口令被拒', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_pw_test');
    addTearDown(() => tmp.deleteSync(recursive: true));

    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过口令模式断言');
      return;
    }

    // init-password：口令走 stdin，不落 argv；mode 应为 password
    final pw = 'P@ssw0rd-口令测试';
    await VaultProcess.initPassword(tmp.path, pw);
    expect(await VaultProcess.isInitialized(tmp.path), isTrue);
    expect(await VaultProcess.mode(tmp.path), 'password',
        reason: '口令模式 vault 的 status 应报 mode=password');

    // 正确口令握手：set/get 全链路（get 返回 base64 载荷，与 OS 模式一致）
    await VaultProcess.set(tmp.path, 'kugou', 'tok-pw', password: pw);
    expect(await VaultProcess.get(tmp.path, 'kugou', password: pw),
        base64Encode(utf8.encode('tok-pw')));

    // 错误口令 → 解锁失败被拒（VaultException；触发锁定退避不影响本用例）
    await expectLater(
      VaultProcess.get(tmp.path, 'kugou', password: 'wrong-password'),
      throwsA(isA<VaultException>()),
    );
  });

  test('设备绑定（v3）：initDevice 本机免密 + clearDeviceSeal 回落口令模式', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_device_test');
    addTearDown(() => tmp.deleteSync(recursive: true));

    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过设备绑定断言');
      return;
    }

    const recovery = 'Recovery-口令';
    // init-device：本机免密 + 可选恢复口令；mode 应为 multiseal
    await VaultProcess.initDevice(tmp.path, recoveryPassword: recovery);
    expect(await VaultProcess.mode(tmp.path), 'multiseal',
        reason: '设备绑定 vault 的 status 应报 mode=multiseal');

    // 本机免密（无口令握手）：set/get 全链路
    await VaultProcess.set(tmp.path, 'kugou', 'tok-bind');
    expect(await VaultProcess.get(tmp.path, 'kugou'),
        base64Encode(utf8.encode('tok-bind')));

    // 错误恢复口令关闭 → 拒绝（VaultException，GCM 认证失败，不触发退避）
    await expectLater(
      VaultProcess.clearDeviceSeal(tmp.path, 'wrong-recovery'),
      throwsA(isA<VaultException>()),
    );

    // 正确恢复口令关闭 → 回落口令模式；熵文件删除；数据以新口令重加密保留
    expect(await VaultProcess.clearDeviceSeal(tmp.path, recovery), isTrue);
    expect(await VaultProcess.mode(tmp.path), 'password',
        reason: '关闭设备绑定后应回落 mode=password');
    expect(File('${tmp.path}/device.seal').existsSync(), isFalse,
        reason: '关闭设备绑定应删除 device.seal 熵文件');

    // 关闭后：新会话口令 = 恢复口令，可回读原数据
    expect(await VaultProcess.get(tmp.path, 'kugou', password: recovery),
        base64Encode(utf8.encode('tok-bind')));
  });

  test('v1 → v3 升级：upgrade-device 免密升级，K 不变数据保留', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_upgrade_v1');
    addTearDown(() => tmp.deleteSync(recursive: true));

    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过升级断言');
      return;
    }

    // v1（OS 份额）初始化 + 写入
    await VaultProcess.init(tmp.path);
    expect(await VaultProcess.mode(tmp.path), 'os');
    await VaultProcess.set(tmp.path, 'kugou', 'tok-v1');

    // 升级：v1 无需口令 → multiseal + device.seal 熵文件
    await VaultProcess.upgradeDevice(tmp.path);
    expect(await VaultProcess.mode(tmp.path), 'multiseal',
        reason: '升级后应为设备绑定 multiseal');
    expect(File('${tmp.path}/device.seal').existsSync(), isTrue,
        reason: '升级应生成设备熵文件 device.seal');

    // 免密回读：K 不变、条目原样沿用（无需重加密）
    expect(await VaultProcess.get(tmp.path, 'kugou'),
        base64Encode(utf8.encode('tok-v1')));

    // 升级后补设恢复口令（multiseal 管理入口）不破坏数据
    await VaultProcess.setRecoveryPassword(tmp.path, 'Recovery-1');
    expect(await VaultProcess.get(tmp.path, 'kugou'),
        base64Encode(utf8.encode('tok-v1')));
  });

  test('v2 → v3 升级：须传会话口令，升级后免密', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_upgrade_v2');
    addTearDown(() => tmp.deleteSync(recursive: true));

    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过 v2 升级断言');
      return;
    }

    const pw = 'P@ss-升级v2';
    await VaultProcess.initPassword(tmp.path, pw);
    expect(await VaultProcess.mode(tmp.path), 'password');
    await VaultProcess.set(tmp.path, 'kugou', 'tok-v2', password: pw);

    // 正确口令升级 → multiseal，升级后免密回读原数据
    await VaultProcess.upgradeDevice(tmp.path, password: pw);
    expect(await VaultProcess.mode(tmp.path), 'multiseal');
    expect(await VaultProcess.get(tmp.path, 'kugou'),
        base64Encode(utf8.encode('tok-v2')));

    // 错误口令升级 → 握手解锁失败被拒（独立目录：触发锁定退避不影响主流程）
    final tmpErr = await Directory.systemTemp.createTemp('vault_upgrade_v2_err');
    addTearDown(() => tmpErr.deleteSync(recursive: true));
    await VaultProcess.initPassword(tmpErr.path, pw);
    await expectLater(
      VaultProcess.upgradeDevice(tmpErr.path, password: 'wrong'),
      throwsA(isA<VaultException>()),
    );
    expect(await VaultProcess.mode(tmpErr.path), 'password',
        reason: '升级失败应保持 v2 口令模式');
  });

  test('v2 口令模式：needsPassword + unlockWithPassword', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_v2_store');
    addTearDown(() => tmp.deleteSync(recursive: true));

    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过 v2 解锁断言');
      return;
    }

    const pw = '会话-口令-42';
    await VaultProcess.initPassword(tmp.path, pw);
    // 注意：Store 读取的 uid 带 `session:` 前缀（VaultSessionStore._uidFor）
    await VaultProcess.set(
        tmp.path, 'session:kugou', jsonEncode({'token': 'tok-v2s'}),
        password: pw);

    // 重建 store（模拟重启）：v2 未解锁 → needsPassword（不静默降级）
    final store = VaultSessionStore(dataDir: tmp.path);
    await store.initialize();
    expect(store.needsPassword, isTrue,
        reason: 'v2 口令模式未解锁应置 needsPassword');
    expect(store.vaultAvailable, isFalse);
    expect(store.get('kugou'), isEmpty);

    // 正确口令 → 解锁成功，数据从 vault 回读
    expect(await store.unlockWithPassword(pw), isTrue);
    expect(store.needsPassword, isFalse);
    expect(store.vaultAvailable, isTrue);
    expect(store.get('kugou'), {'token': 'tok-v2s'});

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

  test('StreamingStore v2：preload 置 needsPassword，解锁后凭据回读', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_ss_v2');
    addTearDown(() {
      StreamingStore.resetForTest();
      tmp.deleteSync(recursive: true);
    });

    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过流媒体 v2 断言');
      return;
    }

    const pw = '流媒体-口令-7';
    await VaultProcess.initPassword(tmp.path, pw);

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

    // 模拟重启（内存态清空）：v2 未解锁 → needsPassword
    StreamingStore.resetForTest();
    StreamingStore.dataDirOverride = tmp.path;
    await StreamingStore.preloadSecrets();
    expect(StreamingStore.needsPassword, isTrue,
        reason: 'v2 未解锁 preload 应置 needsPassword');

    // 正确口令解锁：从 vault 回读凭据
    expect(await StreamingStore.unlockWithPassword(pw), isTrue);
    expect(StreamingStore.needsPassword, isFalse);
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

  test('v1 ↔ v2 互切（switchMode）：K 不变数据沿用 / 口令校验 / 免密回归', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_switch_mode');
    addTearDown(() => tmp.deleteSync(recursive: true));
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过切换断言');
      return;
    }

    // v1（OS 份额）初始化 + 写入（显式 vault 方案：默认偏好为 crypto）
    final store = VaultSessionStore(dataDir: tmp.path, defaultScheme: 'vault');
    await store.initialize();
    expect(store.mode, 'os');
    store.save('kugou', {'token': 'tok-sw'});
    await store.flush();

    // v1 → v2：未传新口令被拒；带新口令成功，新口令即会话口令（本会话解锁）
    await expectLater(
      store.switchMode('password'),
      throwsA(isA<VaultException>()),
    );
    const pw = '新口令-切换';
    await store.switchMode('password', newPassword: pw);
    expect(store.mode, 'password');
    expect(store.vaultAvailable, isTrue,
        reason: '新口令即会话口令，切换后本会话应保持解锁');
    expect(store.needsPassword, isFalse);
    expect(store.sessionPassword, pw);

    // 重启模拟：口令模式需解锁，数据（K 不变、条目未重加密）仍可回读
    final reloaded = VaultSessionStore(dataDir: tmp.path);
    await reloaded.initialize();
    expect(reloaded.mode, 'password');
    expect(reloaded.needsPassword, isTrue);
    expect(await reloaded.unlockWithPassword(pw), isTrue);
    expect(reloaded.get('kugou'), {'token': 'tok-sw'});

    // v2 → v1：本会话已解锁（持口令）→ 免密回归，数据沿用
    await reloaded.switchMode('os');
    expect(reloaded.mode, 'os');
    expect(reloaded.vaultAvailable, isTrue);
    expect(reloaded.sessionPassword, isNull);
    final reloaded2 = VaultSessionStore(dataDir: tmp.path);
    await reloaded2.initialize();
    expect(reloaded2.mode, 'os');
    expect(reloaded2.get('kugou'), {'token': 'tok-sw'});

    // v2 未解锁时切回 os → 握手拒绝，保持口令模式（独立目录，放最后防退避干扰）
    final tmpLocked =
        await Directory.systemTemp.createTemp('vault_switch_locked');
    addTearDown(() => tmpLocked.deleteSync(recursive: true));
    await VaultProcess.initPassword(tmpLocked.path, pw);
    final locked = VaultSessionStore(dataDir: tmpLocked.path);
    await locked.initialize();
    expect(locked.needsPassword, isTrue);
    await expectLater(
      locked.switchMode('os'),
      throwsA(isA<VaultException>()),
    );
    expect(await VaultProcess.mode(tmpLocked.path), 'password',
        reason: '未解锁切回 os 失败应保持口令模式');

    // v3 多封装不可经 switchMode 互切（须走设备绑定关闭入口回落 v2）
    await VaultProcess.upgradeDevice(tmpLocked.path, password: pw);
    final bound = VaultSessionStore(dataDir: tmpLocked.path);
    await bound.initialize();
    expect(bound.isDeviceBound, isTrue);
    await expectLater(
      bound.switchMode('os'),
      throwsA(isA<VaultException>()),
    );
    expect(await VaultProcess.mode(tmpLocked.path), 'multiseal',
        reason: 'v3 被拒后应保持多封装');
  });

  test('未初始化：mode() 返回 null（方案由 prefs 兜底，默认 crypto）', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_mode_uninit');
    addTearDown(() => tmp.deleteSync(recursive: true));
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过未初始化断言');
      return;
    }
    expect(await VaultProcess.isInitialized(tmp.path), isFalse);
    // 未登录/全新数据目录：vault 尚未初始化，模式为 null（不虚构默认 v1），
    // 具体加密方案由 prefs 偏好（默认 crypto）兜底展示
    expect(await VaultProcess.mode(tmp.path), isNull);
  });

  test('v3 无恢复口令：hasRecovery=false，关闭以新口令免授权降级回读', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_v3_norecov_close');
    addTearDown(() => tmp.deleteSync(recursive: true));
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用（缺二进制），跳过');
      return;
    }
    // 免密开启 v3（不设恢复口令 → 纯熵绑定）
    await VaultProcess.initDevice(tmp.path);
    expect(await VaultProcess.hasRecovery(tmp.path), isFalse);
    await VaultProcess.set(tmp.path, 'session:kugou', '{"t":"1"}');
    // 免密关闭绑定：以新口令直接降级（无恢复口令免授权，对称于免密开启）
    final ok = await VaultProcess.clearDeviceSeal(tmp.path, 'new-pw-42');
    expect(ok, isTrue);
    expect(await VaultProcess.mode(tmp.path), 'password');
    expect(await VaultProcess.hasRecovery(tmp.path), isFalse);
    // 新口令解锁回读数据一致
    final raw = await VaultProcess.get(
      tmp.path,
      'session:kugou',
      password: 'new-pw-42',
    );
    expect(utf8.decode(base64Decode(raw!)), '{"t":"1"}');
    // 免密会话已失效（降级后为 password 模式，无口令握手被拒）
    await expectLater(
      VaultProcess.get(tmp.path, 'session:kugou'),
      throwsA(isA<VaultException>()),
    );
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
  });
}
