import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/security/vault_process.dart';
import 'package:archoera_music/services/streaming/streaming_store.dart';
import 'package:archoera_music/services/streaming/streaming_types.dart';

/// 流媒体服务器凭据 vault 化端到端测试（对真实 `archoera-vault` 二进制）：
///   1. save → 配置文件不含凭据，vault 加密存储，重建（清缓存）回读一致
///   2. 旧明文 `streaming_servers.json` 首启 load 自动迁移进 vault 并去密覆写
///   3. 删除服务器 → vault 条目同步删除
///   4. destroy 后 vault 文件消失（密文不可恢复）
///
/// 运行前提（headless 无 Secret Service 时）：
///   ARCHOERA_VAULT_BIN=core/vault/build/archoera-vault-test
///   ARCHOERA_VAULT_INSECURE_FILE_STORE=1
///   （指向测试构建 + 显式启用其明文存储；先跑 core/vault/build-test.sh）。
void main() {
  late Directory tmp;

  setUp(() {
    StreamingStore.resetForTest();
    tmp = Directory.systemTemp.createTempSync('streaming_vault_test');
  });

  tearDown(() {
    StreamingStore.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  StreamingServerConfig cfg({String id = 'srv-1', String password = 'p@ss', String? token}) =>
      StreamingServerConfig(
        id: id,
        name: 'Navidrome',
        type: StreamingServerType.navidrome,
        host: 'nas.local',
        port: 4533,
        username: 'user',
        password: password,
        accessToken: token,
      );

  test('save 后配置文件无凭据，vault 往返回读一致', () async {
    StreamingStore.dataDirOverride = tmp.path;
    StreamingStore.save([cfg(password: 'S3cr3t-密码', token: 'tok-123')], 'srv-1');
    await StreamingStore.flush();
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过持久化断言');
      return;
    }

    // 配置文件剥离凭据
    final raw = jsonDecode(File('${tmp.path}/streaming_servers.json').readAsStringSync())
        as Map<String, dynamic>;
    final serverJson = (raw['servers'] as List).first as Map<String, dynamic>;
    expect(serverJson.containsKey('password'), isFalse, reason: '配置文件不应含 password');
    expect(serverJson.containsKey('accessToken'), isFalse, reason: '配置文件不应含 accessToken');

    // 磁盘无明文（文件 + vault 条目均不含明文串）
    for (final f in tmp.listSync(recursive: true).whereType<File>()) {
      final text = utf8.decode(f.readAsBytesSync(), allowMalformed: true);
      expect(text.contains('S3cr3t-密码'), isFalse, reason: '${f.path} 不应含明文');
      expect(text.contains('tok-123'), isFalse, reason: '${f.path} 不应含明文');
    }

    // 重建（清缓存模拟重启）：先预取凭据（sync load 的凭据来源），再解密回读
    StreamingStore.resetForTest();
    StreamingStore.dataDirOverride = tmp.path;
    await StreamingStore.preloadSecrets();
    final loaded = StreamingStore.load();
    expect(loaded.servers.single.password, 'S3cr3t-密码');
    expect(loaded.servers.single.accessToken, 'tok-123');
    expect(loaded.activeServerId, 'srv-1');
  });

  test('旧明文 streaming_servers.json 首启 load 自动迁移并去密覆写', () async {
    StreamingStore.dataDirOverride = tmp.path;
    // 预置旧明文格式（vault 接管前：password/accessToken 落 JSON）
    File('${tmp.path}/streaming_servers.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
      'servers': [
        {
          'id': 'legacy-1',
          'name': 'Legacy',
          'type': 'subsonic',
          'host': 'old.host',
          'username': 'u',
          'password': 'legacy-pass',
          'accessToken': 'legacy-token',
        }
      ],
      'activeServerId': 'legacy-1',
    }));

    final loaded = StreamingStore.load();
    await StreamingStore.flush();
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过迁移断言');
      return;
    }

    // 内存立即可见
    expect(loaded.servers.single.password, 'legacy-pass');
    expect(loaded.servers.single.accessToken, 'legacy-token');

    // 迁移成功：文件去密 + 明文不再落盘
    final raw = jsonDecode(File('${tmp.path}/streaming_servers.json').readAsStringSync())
        as Map<String, dynamic>;
    final serverJson = (raw['servers'] as List).first as Map<String, dynamic>;
    expect(serverJson.containsKey('password'), isFalse);
    expect(serverJson.containsKey('accessToken'), isFalse);
    for (final f in tmp.listSync(recursive: true).whereType<File>()) {
      final text = utf8.decode(f.readAsBytesSync(), allowMalformed: true);
      expect(text.contains('legacy-pass'), isFalse, reason: '${f.path} 不应含明文');
      expect(text.contains('legacy-token'), isFalse, reason: '${f.path} 不应含明文');
    }

    // 重建（清缓存）：先预取凭据，再从 vault 回读
    StreamingStore.resetForTest();
    StreamingStore.dataDirOverride = tmp.path;
    await StreamingStore.preloadSecrets();
    final reloaded = StreamingStore.load();
    expect(reloaded.servers.single.password, 'legacy-pass');
    expect(reloaded.servers.single.accessToken, 'legacy-token');
  });

  test('删除服务器 → vault 条目同步删除', () async {
    StreamingStore.dataDirOverride = tmp.path;
    StreamingStore.save([cfg(id: 'srv-1'), cfg(id: 'srv-2')], 'srv-1');
    await StreamingStore.flush();
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过删除断言');
      return;
    }

    // 删除 srv-2：save 空列表等价 clearAll（流媒体销毁链路）
    StreamingStore.save([cfg(id: 'srv-1')], 'srv-1');
    await StreamingStore.flush();
    final uid = 'streaming:srv-2';
    final raw = await VaultProcess.get(tmp.path, uid);
    expect(raw == null || raw == 'null', isTrue, reason: '已删除服务器的 vault 条目应清除');
  });

  test('destroy 后 vault 文件消失', () async {
    StreamingStore.dataDirOverride = tmp.path;
    StreamingStore.save([cfg()], 'srv-1');
    await StreamingStore.flush();
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过销毁断言');
      return;
    }
    final vaultFile = File('${tmp.path}/credentials.vault');
    expect(vaultFile.existsSync(), isTrue);

    VaultProcess.destroy(tmp.path);
    expect(vaultFile.existsSync(), isFalse, reason: 'destroy 应删除 vault 文件');
  });
}
