// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// archoerashell CLI 单测：命令解析、全局选项、REST/tool 映射与输出格式。
import 'package:archoera_music/cli/mcp_shell.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Handler = McpShellResponse Function(
  String method,
  Uri uri,
  Object? body,
);

class _Call {
  _Call(this.method, this.uri, this.body);

  final String method;
  final Uri uri;
  final Object? body;
}

class _FakeClient implements McpShellClient {
  _FakeClient(this.target, this.handler);

  final McpShellTarget target;
  final _Handler handler;
  final List<_Call> calls = [];

  @override
  Future<McpShellResponse> get(Uri uri) async {
    calls.add(_Call('GET', uri, null));
    return handler('GET', uri, null);
  }

  @override
  Future<McpShellResponse> send(String method, Uri uri, {Object? body}) async {
    calls.add(_Call(method, uri, body));
    return handler(method, uri, body);
  }

  @override
  void close() {}
}

Future<({int code, String out, String err, _FakeClient? client})> _runShell(
  List<String> args, {
  _Handler? handler,
}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  _FakeClient? client;
  final code = await runMcpShell(
    args,
    defaults: const McpShellOptions(port: 14559, key: 'secret'),
    clientFactory: (target) =>
        client = _FakeClient(target, handler ?? _okHandler),
    out: out,
    err: err,
  );
  return (code: code, out: out.toString(), err: err.toString(), client: client);
}

McpShellResponse _okHandler(String method, Uri uri, Object? body) =>
    const McpShellResponse(200, {'ok': true});

void main() {
  test('--help 输出用法且不建立连接', () async {
    final result = await _runShell(const ['--help']);
    expect(result.code, 0);
    expect(result.out, contains('archoerashell'));
    expect(result.out, contains('用法'));
    expect(result.client, isNull);
  });

  test('--version / -V', () async {
    final result = await _runShell(const ['-V']);
    expect(result.code, 0);
    expect(result.out, contains('MCP'));
  });

  test('无命令 / 未知命令为用法错误（退出码 2）', () async {
    expect((await _runShell(const [])).code, 2);
    final unknown = await _runShell(const ['bogus']);
    expect(unknown.code, 2);
    expect(unknown.err, contains('未知命令'));
  });

  test('status 走 /api/status 并格式化', () async {
    final result = await _runShell(
      const ['status'],
      handler: (m, u, b) => const McpShellResponse(200, {
        'playing': true,
        'positionMs': 61000,
        'durationMs': 180000,
        'volume': 0.8,
        'repeatMode': 'list',
        'shuffle': false,
        'track': {
          'title': 'Song',
          'artists': ['A', 'B'],
          'ref': 'netease:1',
        },
      }),
    );
    expect(result.code, 0);
    expect(result.client!.target.port, 14559);
    expect(result.client!.target.key, 'secret');
    expect(result.client!.calls.single.uri.path, '/api/status');
    expect(result.out, contains('[playing]'));
    expect(result.out, contains('Song — A / B'));
    expect(result.out, contains('01:01 / 03:00'));
  });

  test('全局选项覆盖默认', () async {
    final result = await _runShell(const [
      '--host',
      '10.0.0.2',
      '--port',
      '1234',
      '--key',
      'abc',
      'status',
    ]);
    expect(result.client!.target.host, '10.0.0.2');
    expect(result.client!.target.port, 1234);
    expect(result.client!.target.key, 'abc');
  });

  test('seek / volume / repeat 映射到 REST', () async {
    final seek = await _runShell(const ['seek', '30000']);
    expect(seek.client!.calls.single.method, 'POST');
    expect(seek.client!.calls.single.uri.path, '/api/player/seek');
    expect(seek.client!.calls.single.body, {'positionMs': 30000});

    final volume = await _runShell(const ['volume', '0.5']);
    expect(volume.client!.calls.single.method, 'PUT');
    expect(volume.client!.calls.single.body, {'volume': 0.5});

    final repeat = await _runShell(const ['repeat', 'one']);
    expect(repeat.client!.calls.single.body, {'mode': 'one'});
  });

  test('search 拼接关键词并传递分页选项', () async {
    final result = await _runShell(const [
      'search',
      'netease',
      'Jay',
      'Chou',
      '-n',
      '10',
      '-p',
      '2',
    ]);
    final uri = result.client!.calls.single.uri;
    expect(uri.path, '/api/search');
    expect(uri.queryParameters['source'], 'netease');
    expect(uri.queryParameters['q'], 'Jay Chou');
    expect(uri.queryParameters['limit'], '10');
    expect(uri.queryParameters['page'], '2');
  });

  test('queue add 保留位置参数并读取 --position', () async {
    final result = await _runShell(const [
      'queue',
      'add',
      'n:1',
      'n:2',
      '--position',
      'end',
    ]);
    expect(result.client!.calls.single.uri.path, '/api/queue/add');
    expect(result.client!.calls.single.body, {
      'tracks': ['n:1', 'n:2'],
      'position': 'end',
    });
  });

  test('prefs 拼接 keys', () async {
    final result = await _runShell(const [
      'prefs',
      'mcp.enabled',
      'audio.passthrough',
    ]);
    expect(
      result.client!.calls.single.uri.queryParameters['keys'],
      'mcp.enabled,audio.passthrough',
    );
  });

  test('call 透传工具与 JSON 参数', () async {
    final result = await _runShell(const [
      'call',
      'get_status',
      '--json',
      '{"x":1}',
    ]);
    expect(result.client!.calls.single.uri.path, '/api/tools/get_status');
    expect(result.client!.calls.single.body, {'x': 1});
  });

  test('download add 对多个 ref 逐个入队', () async {
    final result = await _runShell(const [
      'download',
      'add',
      'n:1',
      'n:2',
      '--quality',
      'flac',
    ]);
    expect(result.client!.calls.length, 2);
    expect(result.client!.calls[0].uri.path, '/api/tools/download_add');
    expect(result.client!.calls[0].body, {'ref': 'n:1', 'quality': 'flac'});
    expect(result.client!.calls[1].body, {'ref': 'n:2', 'quality': 'flac'});
  });

  test('sleep 分钟 / --end', () async {
    final byTime = await _runShell(const ['sleep', '30']);
    expect(byTime.client!.calls.single.body, {'minutes': 30});
    final byEnd = await _runShell(const ['sleep', '--end']);
    expect(byEnd.client!.calls.single.body, {'endOfTrack': true});
  });

  test('--json 输出原始 JSON', () async {
    final result = await _runShell(
      const ['--json', 'info'],
      handler: (m, u, b) =>
          const McpShellResponse(200, {'name': 'ArchoeraMusic'}),
    );
    expect(result.out.trim(), '{"name":"ArchoeraMusic"}');
  });

  test('服务端错误映射为退出码 1', () async {
    final result = await _runShell(
      const ['status'],
      handler: (m, u, b) => const McpShellResponse(404, {
        'error': {'code': 'not_found', 'message': 'x'},
      }),
    );
    expect(result.code, 1);
    expect(result.err, contains('not_found'));
  });

  test('queue list 为缺省子命令', () async {
    final result = await _runShell(const ['queue']);
    expect(result.client!.calls.single.uri.path, '/api/queue');
  });

  test('now-playing 不输出缺失字段（无 null）', () async {
    final result = await _runShell(
      const ['now-playing'],
      handler: (m, u, b) => const McpShellResponse(200, {
        'playing': true,
        'positionMs': 1000,
        'durationMs': 2000,
        'track': {
          'title': 'T',
          'artists': ['A'],
        },
      }),
    );
    expect(result.code, 0);
    expect(result.out, contains('[playing]'));
    expect(result.out, contains('T — A'));
    expect(result.out, isNot(contains('null')));
  });
}
