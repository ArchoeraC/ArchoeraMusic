// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// SEC-10：MCP 访问密钥存储单测——偏好 getter 的缓存优先/历史回退、
// prefs.json 历史明文清理，以及 X-Archoera-Key 日志脱敏。
import 'dart:convert';
import 'dart:io';

import 'package:archoera_music/services/log/log.dart';
import 'package:archoera_music/services/mcp/mcp_key_store.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(McpKeyStore.reset);

  test('uidFor 指向凭据保险库条目 mcp:accessKey', () {
    expect(McpKeyStore.uidFor, 'mcp:accessKey');
  });

  test('mcpAccessKey getter 优先返回 vault 缓存', () {
    McpKeyStore.setCached('vault-key');
    final prefs = AppPrefs(initialData: {mcpAccessKeyKey: 'legacy-key'});
    expect(prefs.mcpAccessKey, 'vault-key');
  });

  test('无缓存时回退 prefs.json 历史明文值（并 trim）', () {
    final prefs = AppPrefs(initialData: {mcpAccessKeyKey: '  legacy-key  '});
    expect(prefs.mcpAccessKey, 'legacy-key');
  });

  test('无缓存也无历史值时为空串', () {
    final prefs = AppPrefs();
    expect(prefs.mcpAccessKey, '');
  });

  test('copyWithMcpAccessKey 不再把密钥写回 data（SEC-10）', () {
    final prefs = AppPrefs(initialData: {mcpAccessKeyKey: 'old'});
    final next = prefs.copyWithMcpAccessKey('new-secret');
    expect(next.data.containsKey(mcpAccessKeyKey), isFalse);
    // 缓存/历史均无 → 空串（不会把 'new-secret' 明文留在偏好里）。
    expect(next.mcpAccessKey, '');
  });

  test('readLegacy / clearLegacy 只移除历史明文键，保留其它偏好', () {
    final dir = Directory.systemTemp.createTempSync('mcp-key-store');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/prefs.json');
    f.writeAsStringSync(jsonEncode({
      mcpAccessKeyKey: 'legacy-key',
      'mcp.port': 1234,
    }));

    expect(McpKeyStore.readLegacy(dir.path), 'legacy-key');

    McpKeyStore.clearLegacy(dir.path);
    final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    expect(json.containsKey(mcpAccessKeyKey), isFalse);
    expect(json['mcp.port'], 1234);
    // 幂等：再次清理不报错。
    McpKeyStore.clearLegacy(dir.path);
  });

  test('readLegacy 对缺失/损坏文件返回 null', () {
    final dir = Directory.systemTemp.createTempSync('mcp-key-store-empty');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(McpKeyStore.readLegacy(dir.path), isNull);
    File('${dir.path}/prefs.json').writeAsStringSync('{ not json');
    expect(McpKeyStore.readLegacy(dir.path), isNull);
  });

  test('Log.scrub 掩码 X-Archoera-Key 请求头（SEC-10）', () {
    final out = Log.scrub('X-Archoera-Key: MCPSEKRIT');
    expect(out.contains('MCPSEKRIT'), isFalse);
    expect(out.startsWith('X-Archoera-Key: '), isTrue);
  });
}
