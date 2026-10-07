// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `archoerashell`：随桌面端二进制内置的命令行客户端（类 Unix 终端语法）。
///
/// 用法：`archoera_music archoerashell [全局选项] <命令> [参数...]`
///
/// 通过本机 MCP 控制服务的 REST 接口与运行中的实例通信（默认
/// `127.0.0.1:<prefs.mcpPort>`，携带 `prefs.mcpAccessKey`）。纯 `dart:io`，
/// 不依赖 Flutter；`runMcpShell` 接受可注入的 [McpShellClient]，便于单测。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 默认可连接目标（来自应用偏好：端口 + 访问密钥）。
class McpShellOptions {
  const McpShellOptions({
    this.host = '127.0.0.1',
    required this.port,
    required this.key,
  });

  final String host;
  final int port;
  final String key;
}

/// 解析后的连接目标。
class McpShellTarget {
  const McpShellTarget({
    required this.host,
    required this.port,
    required this.key,
  });

  final String host;
  final int port;
  final String key;

  /// 拼接 REST URL（[path] 形如 `/api/status`）。
  Uri uri(String path, [Map<String, String>? query]) => Uri(
    scheme: 'http',
    host: host,
    port: port,
    path: path,
    queryParameters: (query == null || query.isEmpty) ? null : query,
  );
}

/// 一次 HTTP 响应。
class McpShellResponse {
  const McpShellResponse(this.status, this.body);

  final int status;
  final Object? body;

  bool get ok => status >= 200 && status < 300;

  /// 服务端错误对象 `{"error":{"code","message"}}` 的可读文本。
  String? get errorText {
    final b = body;
    if (b is Map && b['error'] is Map) {
      final err = b['error'] as Map;
      final code = err['code'] ?? 'error';
      final message = err['message'] ?? '';
      return message.toString().isEmpty ? '$code' : '$code: $message';
    }
    return null;
  }
}

/// 传输抽象（测试可注入假实现）。
abstract interface class McpShellClient {
  Future<McpShellResponse> get(Uri uri);
  Future<McpShellResponse> send(String method, Uri uri, {Object? body});
  void close();
}

/// 真实 HTTP 客户端。
class HttpMcpShellClient implements McpShellClient {
  HttpMcpShellClient(this.target)
    : _client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

  final McpShellTarget target;
  final HttpClient _client;

  @override
  Future<McpShellResponse> get(Uri uri) => _send('GET', uri);

  @override
  Future<McpShellResponse> send(String method, Uri uri, {Object? body}) =>
      _send(method, uri, body: body);

  Future<McpShellResponse> _send(String method, Uri uri, {Object? body}) async {
    final request = await _client.openUrl(method, uri);
    if (target.key.isNotEmpty) {
      request.headers.set('X-Archoera-Key', target.key);
    }
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Object? decoded;
    if (text.isNotEmpty) {
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        decoded = text;
      }
    }
    return McpShellResponse(response.statusCode, decoded);
  }

  @override
  void close() => _client.close(force: true);
}

/// 入口：执行一次 shell 调用，返回进程退出码。
///
/// 退出码约定：0 成功 / 1 运行期错误（连接、服务端错误）/ 2 用法错误。
Future<int> runMcpShell(
  List<String> args, {
  required McpShellOptions defaults,
  required McpShellClient Function(McpShellTarget target) clientFactory,
  StringSink? out,
  StringSink? err,
}) async {
  final context = _ShellContext(
    defaults: defaults,
    clientFactory: clientFactory,
    out: out ?? stdout,
    err: err ?? stderr,
  );
  return context.run(args);
}

const String _shellVersion = 'archoerashell 1.0 · MCP 2025-11-25';

class _ShellContext {
  _ShellContext({
    required this.defaults,
    required this.clientFactory,
    required this.out,
    required this.err,
  });

  final McpShellOptions defaults;
  final McpShellClient Function(McpShellTarget target) clientFactory;
  final StringSink out;
  final StringSink err;

  bool json = false;
  bool quiet = false;
  String host = '';
  int port = 0;
  String key = '';
  McpShellClient? _client;

  McpShellTarget get target => McpShellTarget(host: host, port: port, key: key);

  McpShellClient get client => _client ??= clientFactory(target);

  Future<int> run(List<String> argv) async {
    host = defaults.host;
    port = defaults.port;
    key = defaults.key;

    final tokens = List<String>.of(argv);

    // 解析前导全局选项。
    var i = 0;
    while (i < tokens.length) {
      final t = tokens[i];
      if (t == '--') {
        i++;
        break;
      }
      if (t == '-h' || t == '--help') {
        _usage(out);
        return 0;
      }
      if (t == '-V' || t == '--version') {
        out.writeln(_shellVersion);
        return 0;
      }
      if (t == '-j' || t == '--json') {
        json = true;
        i++;
        continue;
      }
      if (t == '-q' || t == '--quiet') {
        quiet = true;
        i++;
        continue;
      }
      if (t == '--host' || t.startsWith('--host=')) {
        final value = _optionValue(t, tokens, i, '--host');
        if (value == null) {
          return _usageError('选项 --host 需要参数');
        }
        host = value.value;
        i += value.consumed;
        continue;
      }
      if (t == '-p' || t == '--port' || t.startsWith('--port=')) {
        final value = _optionValue(
          t == '-p' ? '--port' : t,
          tokens,
          i,
          '--port',
        );
        if (value == null) {
          return _usageError('选项 --port 需要参数');
        }
        final parsed = int.tryParse(value.value);
        if (parsed == null || parsed < 1 || parsed > 65535) {
          return _usageError('端口非法: ${value.value}');
        }
        port = parsed;
        i += value.consumed;
        continue;
      }
      if (t == '-k' || t == '--key' || t.startsWith('--key=')) {
        final value = _optionValue(t == '-k' ? '--key' : t, tokens, i, '--key');
        if (value == null) {
          return _usageError('选项 --key 需要参数');
        }
        key = value.value;
        i += value.consumed;
        continue;
      }
      if (t.startsWith('-') && t.length > 1) {
        return _usageError('未知选项: $t');
      }
      break;
    }

    final command = i < tokens.length ? tokens[i] : '';
    final rest = i < tokens.length ? tokens.sublist(i + 1) : const <String>[];
    if (command.isEmpty) {
      _usage(err);
      return 2;
    }
    if (command == 'help') {
      _usage(out);
      return 0;
    }

    try {
      return await _dispatch(command, rest);
    } on SocketException catch (e) {
      err.writeln(
        '无法连接 ${target.host}:${target.port}（${e.osError?.message ?? e.message}）',
      );
      err.writeln('请确认应用正在运行，且已在「设置 → MCP 接入」中启用服务。');
      return 1;
    } on HttpException catch (e) {
      err.writeln('HTTP 错误: ${e.message}');
      return 1;
    } on TimeoutException {
      err.writeln('连接超时: ${target.host}:${target.port}');
      return 1;
    } finally {
      _client?.close();
    }
  }

  // ── 命令分派 ──────────────────────────────────────────────────

  Future<int> _dispatch(String command, List<String> args) async {
    switch (command) {
      case 'info':
        return _emitGet('/api/info');
      case 'status':
        return _emitGet('/api/status');
      case 'now-playing':
        return _emitGet('/api/now-playing');
      case 'tools':
        return _emitGet('/api/tools');
      case 'play':
      case 'pause':
      case 'toggle':
      case 'stop':
        return _emitSend('POST', '/api/player/$command');
      case 'next':
        return _emitSend('POST', '/api/player/next');
      case 'prev':
      case 'previous':
        return _emitSend('POST', '/api/player/previous');
      case 'seek':
        return _cmdSeek(args);
      case 'volume':
        return _cmdVolume(args);
      case 'repeat':
        return _cmdRepeat(args);
      case 'shuffle':
        return _cmdShuffle(args);
      case 'quality':
        return _cmdQuality(args);
      case 'play-track':
        return _cmdPlayTrack(args);
      case 'search':
        return _cmdSearch(args);
      case 'search-all':
        return _cmdSearchAll(args);
      case 'queue':
        return _cmdQueue(args);
      case 'library':
        return _cmdLibrary(args);
      case 'library-random':
        return _cmdTool('library_random', _limitArgs(args, fallback: 20));
      case 'library-stats':
        return _emitSend('POST', '/api/tools/library_stats');
      case 'prefs':
        return _cmdPrefs(args);
      case 'theme':
        return _cmdTheme(args);
      case 'like':
      case 'unlike':
      case 'like-status':
        return _cmdLike(command, args);
      case 'list-liked':
        return _cmdListLiked(args);
      case 'history':
        return _cmdTool('history_list', _limitArgs(args, fallback: 50));
      case 'history-clear':
        return _emitSend('POST', '/api/tools/history_clear');
      case 'lyrics':
        return _emitSend('POST', '/api/tools/get_lyrics');
      case 'download':
        return _cmdDownload(args);
      case 'sleep':
        return _cmdSleep(args);
      case 'sleep-cancel':
        return _emitSend('POST', '/api/tools/cancel_sleep_timer');
      case 'call':
        return _cmdCall(args);
      default:
        return _usageError('未知命令: $command');
    }
  }

  // ── 命令实现 ──────────────────────────────────────────────────

  Future<int> _cmdSeek(List<String> args) async {
    final ms = _firstInt(args);
    if (ms == null) return _usageError('seek 需要毫秒位置，如 `seek 30000`');
    return _emitSend('POST', '/api/player/seek', {'positionMs': ms});
  }

  Future<int> _cmdVolume(List<String> args) async {
    if (args.isEmpty) return _usageError('volume 需要 0~1 的数值');
    final value = double.tryParse(args.first);
    if (value == null || value < 0 || value > 1) {
      return _usageError('音量必须是 0~1 的数值');
    }
    return _emitSend('PUT', '/api/player/volume', {'volume': value});
  }

  Future<int> _cmdRepeat(List<String> args) async {
    const allowed = ['off', 'list', 'one'];
    if (args.isEmpty || !allowed.contains(args.first)) {
      return _usageError('repeat 需要 off / list / one');
    }
    return _emitSend('PUT', '/api/player/repeat', {'mode': args.first});
  }

  Future<int> _cmdShuffle(List<String> args) async {
    if (args.isEmpty) return _usageError('shuffle 需要 on / off');
    final enabled = _parseOnOff(args.first);
    if (enabled == null) return _usageError('shuffle 需要 on / off');
    return _emitSend('PUT', '/api/player/shuffle', {'enabled': enabled});
  }

  Future<int> _cmdQuality(List<String> args) async {
    const allowed = ['lq', 'sq', 'hq', 'lossless', 'hi-res'];
    if (args.isEmpty || !allowed.contains(args.first)) {
      return _usageError('quality 需要 ${allowed.join(' / ')}');
    }
    return _emitSend('PUT', '/api/player/quality', {'quality': args.first});
  }

  Future<int> _cmdPlayTrack(List<String> args) async {
    if (args.isEmpty) return _usageError('play-track 需要一个曲目 ref');
    return _emitSend('POST', '/api/player/track', {'ref': args.first});
  }

  Future<int> _cmdSearch(List<String> args) async {
    if (args.isEmpty) return _usageError('search 需要 <音源> <关键词>');
    final source = args.first;
    final rest = args.sublist(1);
    final limit = _flagInt(rest, const ['-n', '--limit'], 20);
    final page = _flagInt(rest, const ['-p', '--page'], 1);
    final query = _joinQuery(_stripFlags(rest));
    if (query.isEmpty) return _usageError('search 缺少关键词');
    return _emitGet('/api/search', {
      'source': source,
      'q': query,
      'limit': '$limit',
      'page': '$page',
    });
  }

  Future<int> _cmdSearchAll(List<String> args) async {
    final limit = _flagInt(args, const ['-n', '--limit'], 10);
    final query = _joinQuery(args);
    if (query.isEmpty) return _usageError('search-all 缺少关键词');
    return _cmdTool('search_all', {'query': query, 'limitPerSource': limit});
  }

  Future<int> _cmdQueue(List<String> args) async {
    final sub = args.isEmpty ? 'list' : args.first;
    final rest = args.length > 1 ? args.sublist(1) : const <String>[];
    switch (sub) {
      case 'list':
        return _emitGet('/api/queue');
      case 'play':
        final index = _firstInt(rest);
        if (index == null) return _usageError('queue play 需要索引');
        return _emitSend('POST', '/api/queue/play', {'index': index});
      case 'add':
        final refs = _stripFlags(rest);
        if (refs.isEmpty) return _usageError('queue add 需要曲目 ref');
        final position = _flagValue(args, const ['--position']) ?? 'next';
        return _emitSend('POST', '/api/queue/add', {
          'tracks': refs,
          'position': position,
        });
      case 'rm':
      case 'remove':
        final index = _firstInt(rest);
        if (index == null) return _usageError('queue rm 需要索引');
        return _emitSend('DELETE', '/api/queue/tracks/$index');
      case 'move':
        if (rest.length < 2) return _usageError('queue move 需要 from 与 to');
        final from = int.tryParse(rest[0]);
        final to = int.tryParse(rest[1]);
        if (from == null || to == null) {
          return _usageError('queue move 的 from/to 必须是整数');
        }
        return _emitSend('PUT', '/api/queue/tracks/move', {
          'from': from,
          'to': to,
        });
      case 'clear':
        return _emitSend('DELETE', '/api/queue');
      default:
        return _usageError('未知 queue 子命令: $sub');
    }
  }

  Future<int> _cmdLibrary(List<String> args) async {
    final limit = _flagInt(args, const ['-n', '--limit'], 50);
    final offset = _flagInt(args, const ['--offset'], 0);
    final query = _joinQuery(_stripFlags(args));
    return _emitGet('/api/library/search', {
      if (query.isNotEmpty) 'q': query,
      'limit': '$limit',
      'offset': '$offset',
    });
  }

  Future<int> _cmdPrefs(List<String> args) async {
    final keys = _stripFlags(args);
    return _emitGet('/api/preferences', {
      if (keys.isNotEmpty) 'keys': keys.join(','),
    });
  }

  Future<int> _cmdTheme(List<String> args) async {
    const allowed = ['light', 'dark', 'system'];
    if (args.isEmpty || !allowed.contains(args.first)) {
      return _usageError('theme 需要 light / dark / system');
    }
    return _cmdTool('set_theme_mode', {'mode': args.first});
  }

  Future<int> _cmdLike(String command, List<String> args) async {
    if (args.isEmpty) return _usageError('$command 需要一个曲目 ref');
    const tool = {
      'like': 'like_track',
      'unlike': 'unlike_track',
      'like-status': 'get_like_status',
    };
    return _cmdTool(tool[command]!, {'ref': args.first});
  }

  Future<int> _cmdListLiked(List<String> args) async {
    if (args.isEmpty) return _usageError('list-liked 需要 <音源>');
    final limit = _flagInt(args, const ['-n', '--limit'], 100);
    return _cmdTool('list_liked', {'source': args.first, 'limit': limit});
  }

  Future<int> _cmdDownload(List<String> args) async {
    final sub = args.isEmpty ? 'list' : args.first;
    final rest = args.length > 1 ? args.sublist(1) : const <String>[];
    switch (sub) {
      case 'list':
        return _cmdTool('download_list', _limitArgs(rest, fallback: 50));
      case 'add':
        final refs = _stripFlags(rest);
        if (refs.isEmpty) return _usageError('download add 需要曲目 ref');
        final quality = _flagValue(rest, const ['--quality']);
        var code = 0;
        for (final ref in refs) {
          final result = await _cmdTool('download_add', {
            'ref': ref,
            'quality': ?quality,
          });
          if (result != 0) code = result;
        }
        return code;
      case 'cancel':
        if (rest.isEmpty) return _usageError('download cancel 需要任务 id');
        return _cmdTool('download_cancel', {'taskId': rest.first});
      case 'remove':
        if (rest.isEmpty) return _usageError('download remove 需要任务 id');
        return _cmdTool('download_remove', {'taskId': rest.first});
      default:
        return _usageError('未知 download 子命令: $sub');
    }
  }

  Future<int> _cmdSleep(List<String> args) async {
    if (args.isEmpty) return _usageError('sleep 需要 <分钟> 或 --end');
    if (args.first == '--end' || args.first == 'end') {
      return _cmdTool('set_sleep_timer', {'endOfTrack': true});
    }
    final minutes = int.tryParse(args.first);
    if (minutes == null || minutes <= 0) {
      return _usageError('sleep 分钟数必须是正整数');
    }
    return _cmdTool('set_sleep_timer', {'minutes': minutes});
  }

  Future<int> _cmdCall(List<String> args) async {
    if (args.isEmpty) return _usageError('call 需要 <工具名> [--json <参数>]');
    final name = args.first;
    final rest = args.sublist(1);
    final raw = _flagValue(rest, const ['--json', '--body', '-d']);
    Map<String, dynamic> body = const {};
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          return _usageError('--json 必须是 JSON 对象');
        }
        body = Map<String, dynamic>.from(decoded);
      } catch (_) {
        return _usageError('--json 不是合法 JSON');
      }
    }
    return _emitSend('POST', '/api/tools/$name', body);
  }

  // ── 请求辅助 ──────────────────────────────────────────────────

  Future<int> _emitGet(String path, [Map<String, String>? query]) async {
    final response = await client.get(target.uri(path, query));
    return _finish(response);
  }

  Future<int> _emitSend(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final response = await client.send(method, target.uri(path), body: body);
    return _finish(response);
  }

  Future<int> _cmdTool(String name, Map<String, Object?> args) =>
      _emitSend('POST', '/api/tools/$name', args);

  int _finish(McpShellResponse response) {
    if (!response.ok) {
      final text = response.errorText;
      err.writeln(text == null ? 'HTTP ${response.status}' : '错误: $text');
      return 1;
    }
    if (!quiet) _print(response.body);
    return 0;
  }

  // ── 输出 ──────────────────────────────────────────────────────

  void _print(Object? value) {
    if (json) {
      out.writeln(jsonEncode(value));
      return;
    }
    if (value is Map) {
      _printMap(value.cast<Object?, Object?>());
      return;
    }
    if (value is List) {
      for (final item in value) {
        out.writeln('  $item');
      }
      return;
    }
    out.writeln(value ?? '');
  }

  void _printMap(Map<Object?, Object?> map) {
    if (map['tracks'] is List) {
      _printTracks(map['tracks'] as List, total: map['total']);
      return;
    }
    if (map['entries'] is List) {
      _printTracks(
        map['entries'] as List,
        total: map['total'],
        tag: 'playedAt',
      );
      return;
    }
    if (map['tasks'] is List) {
      _printDownloadTasks(map['tasks'] as List, total: map['total']);
      return;
    }
    if (map['lines'] is List) {
      _printLyrics(map['lines'] as List);
      return;
    }
    if (map['values'] is Map) {
      (map['values'] as Map).forEach((k, v) => out.writeln('$k=$v'));
      return;
    }
    if (map['tools'] is List) {
      _printTools(map['tools'] as List);
      return;
    }
    if (map['sources'] is List) {
      _printSources(map['sources'] as List);
      return;
    }
    if (map.containsKey('playing')) {
      _printStatus(map);
      return;
    }
    map.forEach((k, v) {
      if (v == null) return;
      out.writeln('$k: ${(v is Map || v is List) ? jsonEncode(v) : v}');
    });
  }

  void _printStatus(Map<Object?, Object?> map) {
    final playing = map['playing'] == true;
    final track = map['track'] is Map
        ? (map['track'] as Map).cast<Object?, Object?>()
        : null;
    out.writeln(playing ? '[playing]' : '[paused]');
    if (track != null) {
      out.writeln('${track['title']} — ${_artists(track)}');
      final ref = track['ref'];
      if (ref != null) out.writeln('  ref: $ref');
    }
    final pos = _formatMs(map['positionMs']);
    final dur = _formatMs(map['durationMs']);
    final parts = <String>['$pos / $dur'];
    final volume = map['volume'];
    if (volume != null) parts.add('volume: $volume');
    final repeat = map['repeatMode'];
    if (repeat != null) parts.add('repeat: $repeat');
    if (map['shuffle'] == true) parts.add('shuffle');
    out.writeln(parts.join(' · '));
  }

  void _printTracks(List<Object?> list, {Object? total, String? tag}) {
    if (total != null) out.writeln('# total: $total');
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      if (item is! Map) continue;
      final title = item['title'] ?? '';
      final artists = _artists(item);
      final ref = item['ref'] ?? '';
      final suffix = tag == null ? '' : '  (${item[tag] ?? ''})';
      out.writeln(
        '${(i + 1).toString().padLeft(3)}  $title'
        '${artists.isEmpty ? '' : ' — $artists'}'
        '${ref.toString().isEmpty ? '' : '  [$ref]'}$suffix',
      );
    }
  }

  void _printDownloadTasks(List<Object?> list, {Object? total}) {
    if (total != null) out.writeln('# total: $total');
    for (final item in list) {
      if (item is! Map) continue;
      final progress = item['progress'];
      final pct = progress is num
          ? '${(progress * 100).toStringAsFixed(1)}%'
          : '-';
      out.writeln(
        '${item['status']}  $pct  ${item['title']} — ${item['artist']}'
        '  [${item['taskId']}]',
      );
    }
  }

  void _printLyrics(List<Object?> list) {
    for (final item in list) {
      if (item is! Map) continue;
      final time = _formatMs(item['timeMs']);
      final text = item['text'] ?? '';
      final translation = item['translation'];
      out.writeln(
        '[$time] $text${translation == null ? '' : '  //  $translation'}',
      );
    }
  }

  void _printTools(List<Object?> list) {
    for (final item in list) {
      if (item is! Map) continue;
      out.writeln(
        '${(item['name'] ?? '').toString().padRight(20)} '
        '${item['capability'] ?? ''}  ${item['title'] ?? ''}',
      );
    }
  }

  void _printSources(List<Object?> list) {
    for (final item in list) {
      if (item is! Map) continue;
      final logged = item['loggedIn'] == true ? 'logged-in' : 'logged-out';
      out.writeln('${item['source']}  ${item['label']}  ($logged)');
    }
  }

  static String _artists(Map item) {
    final artists = item['artists'];
    if (artists is List) return artists.join(' / ');
    return (item['artist'] ?? '').toString();
  }

  static String _formatMs(Object? ms) {
    if (ms is! num) return '--:--';
    final total = ms.toInt();
    final seconds = total ~/ 1000;
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ── 参数解析辅助 ──────────────────────────────────────────────

  int _usageError(String message) {
    err.writeln('用法错误: $message');
    err.writeln('运行 `archoerashell --help` 查看用法。');
    return 2;
  }

  /// 选项取值：支持 `--opt value` 与 `--opt=value`；返回 (值, 消耗的 token 数)。
  _OptionValue? _optionValue(
    String token,
    List<String> tokens,
    int index,
    String name,
  ) {
    if (token.contains('=')) {
      return _OptionValue(token.substring(token.indexOf('=') + 1), 1);
    }
    if (index + 1 >= tokens.length) return null;
    return _OptionValue(tokens[index + 1], 2);
  }

  static int? _firstInt(List<String> args) {
    for (final arg in args) {
      if (arg.startsWith('-')) continue;
      final value = int.tryParse(arg);
      if (value != null) return value;
    }
    return null;
  }

  static int _flagInt(List<String> args, List<String> names, int fallback) {
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      for (final name in names) {
        if (arg == name && i + 1 < args.length) {
          final value = int.tryParse(args[i + 1]);
          if (value != null) return value;
        }
        if (arg.startsWith('$name=')) {
          final value = int.tryParse(arg.substring(name.length + 1));
          if (value != null) return value;
        }
      }
    }
    return fallback;
  }

  static String? _flagValue(List<String> args, List<String> names) {
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      for (final name in names) {
        if (arg == name && i + 1 < args.length) return args[i + 1];
        if (arg.startsWith('$name=')) return arg.substring(name.length + 1);
      }
    }
    return null;
  }

  /// 去掉所有 `-x`/`--flag` 形式的 token 及其取值（保留位置参数）。
  ///
  /// 命令级选项（`-n` / `-p` / `--offset` / `--position` / `--quality` /
  /// `--json` 等）均**带取值**，故其后紧跟的非选项 token 一并跳过；
  /// `--flag=value` 形式直接整体跳过。
  static List<String> _stripFlags(List<String> args) {
    final out = <String>[];
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg.startsWith('--') && arg.contains('=')) continue;
      if (arg.startsWith('-')) {
        if (i + 1 < args.length && !args[i + 1].startsWith('-')) i++;
        continue;
      }
      out.add(arg);
    }
    return out;
  }

  static String _joinQuery(List<String> args) => _stripFlags(args).join(' ');

  static Map<String, Object?> _limitArgs(
    List<String> args, {
    required int fallback,
  }) => {
    'limit': _flagInt(args, const ['-n', '--limit'], fallback),
  };

  static bool? _parseOnOff(String value) => switch (value.toLowerCase()) {
    'on' || 'true' || '1' || 'yes' => true,
    'off' || 'false' || '0' || 'no' => false,
    _ => null,
  };

  // ── 用法 ─────────────────────────────────────────────────────

  void _usage(StringSink sink) {
    sink.writeln('''
archoerashell — ArchoeraMusic 命令行控制（类 Unix 语法）

用法:
  archoera_music archoerashell [全局选项] <命令> [参数...]

全局选项:
  -h, --help            显示本帮助
  -V, --version         显示版本
  -j, --json            以 JSON 输出（便于脚本处理）
  -q, --quiet           只输出错误
      --host <host>     服务地址（默认 127.0.0.1）
  -p, --port <port>     服务端口（默认取应用设置）
  -k, --key  <key>      访问密钥（默认取应用设置）

播放:
  status                播放状态
  now-playing           当前曲目
  play | pause | toggle | stop | next | prev
  seek <ms>             跳转毫秒位置
  volume <0..1>         设置音量
  repeat <off|list|one> 循环模式
  shuffle <on|off>      随机播放
  quality <lq|sq|hq|lossless|hi-res>
  play-track <ref>      播放指定曲目

队列:
  queue [list]          查看队列
  queue play <index>    播放队列项
  queue add <ref>...    入队（--position next|end）
  queue rm <index>      移除队列项
  queue move <from> <to>
  queue clear           清空队列

搜索 / 曲库:
  search <source> <关键词> [-n 条数] [-p 页码]
  search-all <关键词> [-n 每源条数]
  library [关键词] [-n 条数] [--offset n]
  library-random [-n 条数]
  library-stats

收藏 / 历史 / 歌词:
  like <ref> | unlike <ref> | like-status <ref>
  list-liked <source> [-n 条数]
  history [-n 条数] | history-clear
  lyrics

下载:
  download [list] [-n 条数]
  download add <ref>... [--quality <档位>]
  download cancel <taskId>
  download remove <taskId>

其它:
  theme <light|dark|system>
  sleep <分钟> | sleep --end | sleep-cancel
  prefs [键...]          读取应用偏好
  tools                  列出已启用工具
  info                   服务信息
  call <工具名> [--json '<参数对象>']

示例:
  archoera_music archoerashell status
  archoera_music archoerashell search netease 周杰伦 -n 10
  archoera_music archoerashell play-track netease:186016
  archoera_music archoerashell --json library 周杰伦
''');
  }
}

class _OptionValue {
  const _OptionValue(this.value, this.consumed);

  final String value;
  final int consumed;
}
