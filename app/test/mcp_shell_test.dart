// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// archoerashell CLI 单测：命令解析、全局选项、REST/tool 映射与输出格式。
import 'package:archoera_music/cli/mcp_shell.dart';
import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:flutter/widgets.dart' show Locale;
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
  AppLocalizations? l10n,
}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  _FakeClient? client;
  final code = await runMcpShell(
    args,
    defaults: const McpShellOptions(port: 14559, key: 'secret'),
    clientFactory: (target) =>
        client = _FakeClient(target, handler ?? _okHandler),
    // 默认 en：渲染标签断言用英文；需要测其它语言时显式传 l10n。
    l10n: l10n ?? lookupAppLocalizations(const Locale('en')),
    out: out,
    err: err,
  );
  return (code: code, out: out.toString(), err: err.toString(), client: client);
}

McpShellResponse _okHandler(String method, Uri uri, Object? body) =>
    const McpShellResponse(200, {'ok': true});

/// 强制 TUI 渲染（模拟交互式终端），用于校验面板/表格/进度条版式。
Future<({int code, String out, String err})> _runStyled(
  List<String> args, {
  _Handler? handler,
  int columns = 80,
  AppLocalizations? l10n,
}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = await runMcpShell(
    args,
    defaults: const McpShellOptions(port: 14559, key: 'secret'),
    clientFactory: (target) => _FakeClient(target, handler ?? _okHandler),
    l10n: l10n ?? lookupAppLocalizations(const Locale('en')),
    out: out,
    err: err,
    styled: true,
    columns: columns,
  );
  return (code: code, out: out.toString(), err: err.toString());
}

/// 测试用显示宽度（与渲染器同口径：CJK 宽字符 2 列、暗色为 0）。
int _width(String s) {
  final plain = s.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '');
  var w = 0;
  for (final rune in plain.runes) {
    if ((rune >= 0x1100 && rune <= 0x115f) ||
        (rune >= 0x2e80 && rune <= 0x303e) ||
        (rune >= 0x3041 && rune <= 0x33ff) ||
        (rune >= 0x3400 && rune <= 0x4dbf) ||
        (rune >= 0x4e00 && rune <= 0x9fff) ||
        (rune >= 0xac00 && rune <= 0xd7a3) ||
        (rune >= 0xff00 && rune <= 0xff60)) {
      w += 2;
    } else {
      w += 1;
    }
  }
  return w;
}

void main() {
  test('--help 输出用法且不建立连接', () async {
    final result = await _runShell(const ['--help']);
    expect(result.code, 0);
    expect(result.out, contains('archoerashell'));
    expect(result.out, contains('Usage'));
    expect(result.client, isNull);
  });

  test('--version / -V', () async {
    final result = await _runShell(const ['-V']);
    expect(result.code, 0);
    expect(result.out, contains('MCP'));
  });

  test('子命令 --help / help <命令>', () async {
    final a = await _runShell(const ['search', '--help']);
    expect(a.code, 0);
    expect(a.client, isNull);
    expect(a.out, contains('archoerashell search'));
    expect(a.out, contains('--limit'));

    final b = await _runShell(const ['help', 'queue']);
    expect(b.code, 0);
    expect(b.out, contains('queue add'));

    final c = await _runShell(const ['download', '-h']);
    expect(c.code, 0);
    expect(c.out, contains('download add'));

    final d = await _runShell(const ['help']);
    expect(d.code, 0);
    expect(d.out, contains('per-command'));
  });

  test('文案跟随语言设置（en）', () async {
    final en = lookupAppLocalizations(const Locale('en'));
    final help = await _runShell(const ['search', '--help'], l10n: en);
    expect(help.code, 0);
    expect(help.out, contains('Usage: archoerashell search'));

    final unknown = await _runShell(const ['bogus'], l10n: en);
    expect(unknown.code, 2);
    expect(unknown.err, contains('Unknown command'));

    final usage = await _runShell(const ['seek'], l10n: en);
    expect(usage.code, 2);
    expect(usage.err, contains('Usage error'));
    expect(usage.err, contains('Usage: archoerashell seek'));

    final total = await _runShell(const ['--help'], l10n: en);
    expect(total.out, contains('Global options'));
  });

  test('无命令 / 未知命令为用法错误（退出码 2）', () async {
    expect((await _runShell(const [])).code, 2);
    final unknown = await _runShell(const ['bogus']);
    expect(unknown.code, 2);
    expect(unknown.err, contains('Unknown command'));

    // 跟随应用语言（中文）时文案切换。
    final zh = lookupAppLocalizations(const Locale('zh'));
    final unknownZh = await _runShell(const ['bogus'], l10n: zh);
    expect(unknownZh.err, contains('未知命令'));
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
    // 本地化错误前缀（默认 en；不再硬编码中文）。
    expect(result.err, contains('Error: not_found'));

    final zh = await _runShell(
      const ['status'],
      l10n: lookupAppLocalizations(const Locale('zh')),
      handler: (m, u, b) => const McpShellResponse(404, {
        'error': {'code': 'not_found', 'message': 'x'},
      }),
    );
    expect(zh.err, contains('错误'));
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

  test('search-all 按源分组展示（不再甩 JSON）', () async {
    final result = await _runShell(
      const ['search-all', 'hazy'],
      handler: (m, u, b) => const McpShellResponse(200, {
        'query': 'hazy',
        'results': [
          {
            'source': 'netease',
            'total': 300,
            'hasMore': true,
            'tracks': [
              {
                'ref': 'netease:1',
                'title': 'Hazy',
                'artists': ['A'],
              },
            ],
          },
          {'source': 'kugou', 'error': 'boom', 'tracks': <Object?>[]},
        ],
      }),
    );
    expect(result.code, 0);
    expect(result.out, contains('query: hazy'));
    expect(result.out, contains('── netease（300+）'));
    expect(result.out, contains('Hazy — A'));
    expect(result.out, contains('── kugou: error boom'));
    expect(result.out, isNot(contains('"source"')));
  });

  test('TUI status 渲染面板 + 进度条 + 元信息', () async {
    final result = await _runStyled(
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
    expect(result.out, contains('╭─'));
    expect(result.out, contains('╰'));
    expect(result.out, contains('Playing'));
    expect(result.out, contains('Song'));
    expect(result.out, contains('A / B'));
    expect(result.out, contains('█')); // 已播放部分
    expect(result.out, contains('░')); // 未播放部分
    expect(result.out, contains('01:01 / 03:00'));
    expect(result.out, contains('netease:1'));
    expect(result.out, contains('vol 80%'));
    expect(result.out, contains('repeat list'));
    expect(result.out, isNot(contains('[playing]')));
  });

  test('TUI 面板各行等宽（含中文标题也不越界）', () async {
    final result = await _runStyled(
      const ['status'],
      handler: (m, u, b) => const McpShellResponse(200, {
        'playing': true,
        'positionMs': 148000,
        'durationMs': 252000,
        'track': {
          'title': '我恨明月不照我',
          'artists': ['阿YueYue'],
          'ref': 'neko:25880',
        },
      }),
      columns: 80,
    );
    final panel = result.out
        .split('\n')
        .where((l) => l.contains('│') || l.contains('╭') || l.contains('╰'))
        .toList();
    expect(panel.length, greaterThanOrEqualTo(4));
    final widths = panel.map(_width).toSet();
    expect(widths, hasLength(1));
  });

  test('TUI 队列用 ▶ 标记当前曲目', () async {
    final result = await _runStyled(
      const ['queue'],
      handler: (m, u, b) => const McpShellResponse(200, {
        'tracks': [
          {'index': 0, 'isCurrent': false, 'title': 'Intro', 'artists': ['A'], 'ref': 'n:1'},
          {'index': 1, 'isCurrent': true, 'title': 'Now', 'artists': ['B'], 'ref': 'n:2'},
        ],
      }),
    );
    expect(result.out, contains('▶'));
    expect(result.out, contains('Intro'));
    expect(result.out, contains('Now'));
    expect(result.out, contains('Title'));
    // 非当前行保留序号。
    expect(result.out, contains('1'));
  });

  test('TUI 列表为空时给出占位', () async {
    final result = await _runStyled(
      const ['library'],
      handler: (m, u, b) =>
          const McpShellResponse(200, {'tracks': <Object?>[], 'total': 0}),
    );
    expect(result.out, contains('total 0'));
    expect(result.out, contains('empty'));
  });

  test('TUI 未启用时回退纯文本（无 ANSI 转义）', () async {
    final result = await _runShell(
      const ['status'],
      handler: (m, u, b) => const McpShellResponse(200, {
        'playing': false,
        'positionMs': 0,
        'durationMs': 0,
        'track': {'title': 'T', 'artists': ['A']},
      }),
    );
    expect(result.out, contains('[paused]'));
    expect(result.out, isNot(contains('\x1b[')));
  });

  test('--json 优先于 TUI（输出原始 JSON）', () async {
    final result = await _runStyled(
      const ['--json', 'info'],
      handler: (m, u, b) =>
          const McpShellResponse(200, {'name': 'ArchoeraMusic'}),
    );
    expect(result.out.trim(), '{"name":"ArchoeraMusic"}');
    expect(result.out, isNot(contains('\x1b[')));
  });

  test('TUI info 渲染服务信息与能力组面板', () async {
    final result = await _runStyled(
      const ['info'],
      handler: (m, u, b) => const McpShellResponse(200, {
        'name': 'ArchoeraMusic',
        'version': '0.9.20+7',
        'platform': 'linux',
        'service': {
          'port': 14559,
          'lan': false,
          'protocolVersion': '2025-11-25',
          'endpoints': {'mcp': '/mcp', 'rest': '/api', 'websocket': '/ws'},
          'capabilities': ['read', 'playback', 'download'],
        },
      }),
    );
    expect(result.out, contains('╭─'));
    expect(result.out, contains('ArchoeraMusic'));
    expect(result.out, contains('version'));
    expect(result.out, contains('0.9.20+7'));
    expect(result.out, contains('loopback'));
    expect(result.out, contains('/mcp'));
    expect(result.out, contains('caps'));
    expect(result.out, contains('download'));
  });

  test('TUI library-stats 使用人类可读单位', () async {
    final result = await _runStyled(
      const ['library-stats'],
      handler: (m, u, b) => const McpShellResponse(200, {
        'tracks': 1287,
        'totalSizeBytes': 16437698560,
        'totalDurationMs': 20523000,
      }),
    );
    expect(result.out, contains('Library'));
    expect(result.out, contains('1287'));
    expect(result.out, contains('GiB'));
    expect(result.out, contains('5h 42m'));
  });

  test('TUI 动作结果渲染为勾号摘要', () async {
    final volume = await _runStyled(
      const ['volume', '0.5'],
      handler: (m, u, b) =>
          const McpShellResponse(200, {'ok': true, 'volume': 0.5}),
    );
    expect(volume.out, contains('✓'));
    expect(volume.out, contains('vol 50%'));

    final sleep = await _runStyled(
      const ['sleep', '30'],
      handler: (m, u, b) =>
          const McpShellResponse(200, {'ok': true, 'mode': 'duration', 'minutes': 30}),
    );
    expect(sleep.out, contains('sleep'));
    expect(sleep.out, contains('30m'));

    final liked = await _runStyled(
      const ['like-status', 'neko:1'],
      handler: (m, u, b) =>
          const McpShellResponse(200, {'ref': 'neko:1', 'liked': true}),
    );
    expect(liked.out, contains('♥'));
    expect(liked.out, contains('liked'));
  });

  test('TUI 搜索/队列/历史带上下文头部', () async {
    final search = await _runStyled(
      const ['search', 'netease', 'x'],
      handler: (m, u, b) => const McpShellResponse(200, {
        'source': 'netease',
        'query': 'Assumptions',
        'page': 1,
        'total': 30,
        'tracks': [
          {'ref': 'netease:1', 'title': 'Assumptions', 'artists': ['A']},
        ],
      }),
    );
    expect(search.out, contains('search'));
    expect(search.out, contains('Assumptions'));
    expect(search.out, contains('page 1'));
    expect(search.out, contains('total 30'));

    final queue = await _runStyled(
      const ['queue'],
      handler: (m, u, b) => const McpShellResponse(200, {
        'index': 1,
        'repeatMode': 'one',
        'shuffle': true,
        'tracks': [
          {'index': 0, 'isCurrent': false, 'title': 'A', 'artists': ['x'], 'ref': 'n:1'},
          {'index': 1, 'isCurrent': true, 'title': 'B', 'artists': ['y'], 'ref': 'n:2'},
        ],
      }),
    );
    expect(queue.out, contains('index 2/2'));
    expect(queue.out, contains('repeat one'));
    expect(queue.out, contains('shuffle on'));

    final history = await _runStyled(
      const ['history'],
      handler: (m, u, b) => McpShellResponse(200, {
        'total': 1,
        'entries': [
          {
            'title': 'Hazy',
            'artists': ['A'],
            'ref': 'n:1',
            'playedAt': DateTime.now().millisecondsSinceEpoch - 7200000,
          },
        ],
      }),
    );
    expect(history.out, contains('When'));
    expect(history.out, contains('ago'));
  });

  test('TUI ref 列优先完整显示（长标题也不截断 ref）', () async {
    final result = await _runStyled(
      const ['search', 'netease', 'x'],
      columns: 60,
      handler: (m, u, b) => const McpShellResponse(200, {
        'source': 'netease',
        'query': 'q',
        'tracks': [
          {
            'ref': 'netease:1843699265',
            'title': '这是一个相当长的歌曲标题用来挤占列宽应该被截断',
            'artists': ['An artist name'],
          },
        ],
      }),
    );
    // ref 完整保留，未被 `…` 截断。
    expect(result.out, contains('netease:1843699265'));
    expect(result.out, isNot(contains('netease:1843699…')));
    // 被挤占的应是标题列。
    expect(result.out, contains('…'));
  });

  test('TUI 窄终端下所有行不越界（含超长文本）', () async {
    const columns = 30;
    final longTitle = '这是一个非常非常非常非常非常非常长的歌曲标题应该被截断';
    final status = await _runStyled(
      const ['status'],
      columns: columns,
      handler: (m, u, b) => McpShellResponse(200, {
        'playing': true,
        'positionMs': 148000,
        'durationMs': 252000,
        'volume': 1.0,
        'repeatMode': 'off',
        'quality': 'lossless',
        'track': {
          'title': longTitle,
          'artists': ['一个也很长很长的歌手名字组合'],
          'ref': 'neko:25880',
        },
      }),
    );
    final tracks = await _runStyled(
      const ['search', 'netease', 'x'],
      columns: columns,
      handler: (m, u, b) => McpShellResponse(200, {
        'source': 'netease',
        'query': longTitle,
        'page': 1,
        'total': 1,
        'tracks': [
          {
            'ref': 'netease:1843699265',
            'title': longTitle,
            'artists': ['A very very very long artist name that overflows'],
          },
        ],
      }),
    );
    final info = await _runStyled(
      const ['info'],
      columns: columns,
      handler: (m, u, b) => const McpShellResponse(200, {
        'name': 'ArchoeraMusic',
        'version': '0.9.20+7',
        'platform': 'linux',
        'service': {
          'port': 14559,
          'lan': true,
          'protocolVersion': '2025-11-25',
          'endpoints': {'mcp': '/mcp', 'rest': '/api', 'websocket': '/ws'},
          'capabilities': [
            'read',
            'playback',
            'queue',
            'search',
            'library',
            'preferences',
            'appearance',
            'collection',
            'history',
            'lyrics',
            'download',
          ],
        },
      }),
    );
    for (final out in [status.out, tracks.out, info.out]) {
      for (final line in out.split('\n')) {
        expect(
          _width(line),
          lessThanOrEqualTo(columns),
          reason: '越界行: ${line.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '')}',
        );
      }
    }
    expect(tracks.out, contains('…'));
  });

  test('渲染标签跟随语言（zh 纯文本 + TUI）', () async {
    final zh = lookupAppLocalizations(const Locale('zh'));
    final plain = await _runShell(
      const ['status'],
      l10n: zh,
      handler: (m, u, b) => const McpShellResponse(200, {
        'playing': false,
        'positionMs': 1000,
        'durationMs': 2000,
        'volume': 0.8,
        'repeatMode': 'off',
        'track': {'title': 'T', 'artists': ['A'], 'ref': 'n:1'},
      }),
    );
    expect(plain.out, contains('[暂停]'));
    expect(plain.out, contains('音量: 0.8'));
    expect(plain.out, contains('循环: off'));

    final tui = await _runStyled(
      const ['status'],
      l10n: zh,
      handler: (m, u, b) => const McpShellResponse(200, {
        'playing': true,
        'positionMs': 1000,
        'durationMs': 2000,
        'volume': 1.0,
        'track': {'title': 'T', 'artists': ['A'], 'ref': 'n:1'},
      }),
    );
    expect(tui.out, contains('播放中'));
    expect(tui.out, contains('音量 100%'));

    final queue = await _runStyled(
      const ['queue'],
      l10n: zh,
      handler: (m, u, b) => const McpShellResponse(200, {
        'index': 0,
        'repeatMode': 'off',
        'shuffle': false,
        'tracks': [
          {'index': 0, 'isCurrent': true, 'title': 'A', 'artists': ['x'], 'ref': 'n:1'},
        ],
      }),
    );
    expect(queue.out, contains('队列'));
    expect(queue.out, contains('序号 1/1'));
  });
}
