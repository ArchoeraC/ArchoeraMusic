// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

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
///   ARCHOERA_VAULT_BIN=core/vault-rs/build/archoera-vault-test
///   ARCHOERA_VAULT_BACKEND=file
///   （指向测试构建 + 选择生产 FileStore 文件密钥后端；先跑
///   core/vault-rs/build-test.sh。SEC-19 后不再有测试明文存储后门）。
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

    // 重建（清缓存模拟重启）：preloadSecrets 不批量解密，凭据惰性加载
    StreamingStore.resetForTest();
    StreamingStore.dataDirOverride = tmp.path;
    await StreamingStore.preloadSecrets();
    final before = StreamingStore.load();
    expect(before.servers.single.password, isEmpty,
        reason: 'preloadSecrets 不得逐服务器解密（SEC-03）');
    expect(before.servers.single.accessToken, isNull);
    expect(before.activeServerId, 'srv-1');
    expect(StreamingStore.hasSecret('srv-1'), isFalse,
        reason: '未 loadSecret 前不得有内存凭据');
    await StreamingStore.loadSecret('srv-1');
    expect(StreamingStore.hasSecret('srv-1'), isTrue);
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

    // 重建（清缓存）：preloadSecrets 不批量解密，loadSecret 按需回读
    StreamingStore.resetForTest();
    StreamingStore.dataDirOverride = tmp.path;
    await StreamingStore.preloadSecrets();
    expect(StreamingStore.load().servers.single.password, isEmpty,
        reason: 'preloadSecrets 不得逐服务器解密（SEC-03）');
    await StreamingStore.loadSecret('legacy-1');
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

  test('save 不带凭据（改名/排序）不覆盖既有 vault 凭据', () async {
    StreamingStore.dataDirOverride = tmp.path;
    final orig = cfg(id: 'srv-1', password: 'keep-me', token: 'tok-keep');
    StreamingStore.save([orig], 'srv-1');
    await StreamingStore.flush();
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过断言');
      return;
    }
    await StreamingStore.loadSecret('srv-1');
    expect(StreamingStore.cachedSecret('srv-1')?['password'], 'keep-me');

    // metadata-only 改动（状态中只有元数据、无凭据）：改名 + 空 password
    final metaOnly = orig.withoutSecrets().copyWith(name: 'Renamed');
    expect(metaOnly.password, isEmpty);
    StreamingStore.save([metaOnly], 'srv-1');
    await StreamingStore.flush();

    // 既有条目未被空 payload 覆盖
    final raw = await VaultProcess.get(tmp.path, 'streaming:srv-1');
    expect(raw != null && raw != 'null', isTrue, reason: 'metadata-only 保存不得删除凭据');

    // 重建回读一致（password + token 均在）
    StreamingStore.resetForTest();
    StreamingStore.dataDirOverride = tmp.path;
    await StreamingStore.loadSecret('srv-1');
    final sec = StreamingStore.cachedSecret('srv-1');
    expect(sec?['password'], 'keep-me');
    expect(sec?['accessToken'], 'tok-keep');
  });

  test('删除未加载凭据的服务器也删除 vault 条目', () async {
    StreamingStore.dataDirOverride = tmp.path;
    StreamingStore.save([cfg(id: 'srv-1'), cfg(id: 'srv-2')], 'srv-1');
    await StreamingStore.flush();
    if (!VaultProcess.available) {
      markTestSkipped('vault 不可用，跳过删除断言');
      return;
    }

    // 清缓存（模拟从未 loadSecret 的重启）后删除 srv-2：
    // 删除须经磁盘既有 id 判定，而非仅内存缓存
    StreamingStore.resetForTest();
    StreamingStore.dataDirOverride = tmp.path;
    StreamingStore.save([cfg(id: 'srv-1')], 'srv-1');
    await StreamingStore.flush();
    final raw = await VaultProcess.get(tmp.path, 'streaming:srv-2');
    expect(raw == null || raw == 'null', isTrue,
        reason: '未加载凭据的服务器删除后条目也应清除');
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
