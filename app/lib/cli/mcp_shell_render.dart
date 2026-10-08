// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `archoerashell` 的人类可读输出渲染器（TUI 风格）。
///
/// 仅在 `stdout` 为交互式终端时启用（见 `mcp_shell.dart` 的自动探测）：
/// ANSI 配色/样式、圆角面板、对齐列与进度条，风格贴近 OpenCode 等
/// Agent 交互式终端。非终端（管道 / 重定向 / 单测）由 `mcp_shell.dart`
/// 走纯文本分支，保证脚本与 `--json` 输出稳定。
///
/// 渲染器不做 JSON 输出——`--json` 由 `mcp_shell.dart` 直接 `jsonEncode`。
/// 宽度计算按终端显示列（East Asian 宽字符按 2 列、组合符按 0 列）进行，
/// 因此中文标题/歌手也能与边框对齐。
library;

import 'dart:math' as math;

import '../l10n/generated/app_localizations.dart';

/// 仅匹配 SGR 序列；宽度计算时先剔除，得到真实显示列数。
final RegExp _sgr = RegExp(r'\x1b\[[0-9;]*m');

/// 将结构化输出渲染为 TUI 文本并写入 [out]。
class McpShellRenderer {
  const McpShellRenderer({
    required this.out,
    required this.columns,
    required this.l10n,
  });

  final StringSink out;

  /// 终端可用列数（用于面板/表格/进度条宽度预算）。
  final int columns;

  /// 命令行本地化（标签与帮助同源）。
  final AppLocalizations l10n;

  // ── 样式 ──────────────────────────────────────────────────────

  String _sgrCode(String code, String s) => '\x1b[${code}m$s\x1b[0m';
  String _bold(String s) => _sgrCode('1', s);
  String _dim(String s) => _sgrCode('2', s);
  String _italic(String s) => _sgrCode('3', s);
  String _red(String s) => _sgrCode('31', s);
  String _green(String s) => _sgrCode('32', s);
  String _yellow(String s) => _sgrCode('33', s);
  String _cyan(String s) => _sgrCode('36', s);

  /// 输出一行；超出终端宽度时强制截断（含 ANSI 复位），避免换行破坏排版。
  void _write(String line) {
    final text = (columns > 0 && _displayWidth(line) > columns)
        ? _truncate(line, columns)
        : line;
    out.writeln(text);
  }

  // ── 顶层分派（对应纯文本分支的各类结构） ────────────────────

  /// 未知结构的兜底：缩进递归（Map/List），键着色为青色。
  void indented(Object? value, [String indent = '  ']) {
    if (value is Map) {
      value.forEach((k, v) {
        if (v == null) return;
        if (v is Map || v is List) {
          _write('$indent${_cyan(k.toString())}${_dim(':')}');
          indented(v, '$indent  ');
        } else {
          _write('$indent${_cyan(k.toString())}${_dim(':')} $v');
        }
      });
      return;
    }
    if (value is List) {
      for (final item in value) {
        if (item is Map || item is List) {
          _write('$indent${_dim('·')}');
          indented(item, '$indent  ');
        } else {
          _write('$indent${_dim('·')} $item');
        }
      }
      return;
    }
    _write('$indent$value');
  }

  /// 标量值。
  void scalar(Object? value) => _write(value?.toString() ?? '');

  /// 标量列表（逐项着色项目符号）。
  void listed(List<Object?> items) {
    for (final item in items) {
      _write('  ${_dim('•')} $item');
    }
  }

  /// 偏好键值（`key = value`，键列对齐）。
  void values(Map<Object?, Object?> map) {
    if (map.isEmpty) {
      _write(_dim('  · ${l10n.mcpShellLblEmpty}'));
      return;
    }
    final keyW = map.keys
        .map((k) => _displayWidth(k.toString()))
        .fold(0, math.max)
        .clamp(0, 28);
    map.forEach((k, v) {
      _write('  ${_cyan(_fit(k.toString(), keyW))}  ${_dim('=')}  $v');
    });
  }

  // ── 播放状态 ──────────────────────────────────────────────────

  /// 播放状态面板：状态图标 + 曲目 + 进度条 + 元信息。
  void status(Map<Object?, Object?> map) {
    final playing = map['playing'] == true;
    final buffering = map['buffering'] == true;
    final track = map['track'] is Map
        ? (map['track'] as Map).cast<Object?, Object?>()
        : const <Object?, Object?>{};
    final title = (track['title'] ?? map['title'] ?? '').toString();
    final artists = _artists(track.isEmpty ? map : track);

    final stateWord = buffering
        ? l10n.mcpShellLblBuffering
        : (playing ? l10n.mcpShellLblPlaying : l10n.mcpShellLblPaused);
    final icon = buffering
        ? '◌'
        : (playing ? '▶' : '⏸');
    final String Function(String) accent = buffering
        ? _yellow
        : (playing ? _green : _yellow);

    final meta = <String>[];
    final ref = track['ref'];
    if (ref != null) meta.add(_dim(ref.toString()));
    final volume = map['volume'];
    if (volume is num) {
      meta.add(_dim('${l10n.mcpShellLblVolume} ${(volume * 100).round()}%'));
    }
    final quality = map['quality'];
    if (quality != null) {
      meta.add(_dim('${l10n.mcpShellLblQuality} $quality'));
    }
    final repeat = map['repeatMode'];
    if (repeat != null) {
      meta.add(_dim('${l10n.mcpShellLblRepeat} $repeat'));
    }
    if (map['shuffle'] == true) meta.add(_dim(l10n.mcpShellLblShuffleOn));
    final metaLine = meta.join(_dim(' · '));

    final pos = _formatMs(map['positionMs']);
    final dur = _formatMs(map['durationMs']);
    final time = '$pos / $dur';

    final head = <String>[
      '${accent(icon)}  ${_bold(title.isEmpty ? '—' : title)}',
      if (artists.isNotEmpty) '${' ' * 3}${_dim(artists)}',
    ];

    const pad = 2;
    final timeW = _displayWidth(time);
    const minBar = 10;
    final cap = math.max(8, math.min(columns - 2, 72));
    var inner = <int>[
      ...head.map(_displayWidth),
      if (metaLine.isNotEmpty) _displayWidth(metaLine),
      timeW + 2 + minBar,
    ].reduce(math.max) +
        pad * 2;
    inner = inner.clamp(math.min(24, cap), cap);

    final contentW = inner - pad * 2;
    final bar = _bar(
      _ratio(map['positionMs'], map['durationMs']),
      contentW - timeW - 2,
    );

    final body = <String>[
      ...head,
      '',
      bar.isEmpty ? _dim(time) : '$bar  ${_dim(time)}',
      if (metaLine.isNotEmpty) '',
      if (metaLine.isNotEmpty) metaLine,
    ];

    _panel(
      title: '${accent('♪')} ${_bold(stateWord)}',
      body: body,
      pad: pad,
      inner: inner,
    );
  }

  /// 服务信息面板（`info`）：版本 / 平台 / 端口 / 协议 / 端点 / 能力组。
  void info(Map<Object?, Object?> map) {
    const pad = 2;
    final name = (map['name'] ?? 'ArchoeraMusic').toString();
    final labels = [
      l10n.mcpShellLblVersion,
      l10n.mcpShellLblPlatform,
      l10n.mcpShellLblPort,
      l10n.mcpShellLblProtocol,
      l10n.mcpShellLblEndpoints,
      l10n.mcpShellLblCaps,
    ];
    final labelW = labels.map(_displayWidth).reduce(math.max);
    final target = math.max(28, math.min(columns - 2, 68)) - pad * 2;

    String kv(String label, String value) =>
        '${_dim(_fit(label, labelW))}  $value';

    final body = <String>[];
    if (map['version'] != null) {
      body.add(kv(labels[0], map['version'].toString()));
    }
    if (map['platform'] != null) {
      body.add(kv(labels[1], map['platform'].toString()));
    }

    final service = map['service'] is Map
        ? (map['service'] as Map).cast<Object?, Object?>()
        : null;
    if (service != null) {
      body.add('');
      final port = service['port'];
      if (port != null) {
        final scope = service['lan'] == true
            ? l10n.mcpShellLblLan
            : l10n.mcpShellLblLoopback;
        body.add(kv(labels[2], '$port  ${_dim('($scope)')}'));
      }
      if (service['protocolVersion'] != null) {
        body.add(kv(labels[3], service['protocolVersion'].toString()));
      }
      final endpoints = service['endpoints'];
      if (endpoints is Map) {
        final parts = <String>[
          for (final e in endpoints.entries)
            '${_dim('${e.key} ')}${_cyan(e.value.toString())}',
        ];
        body.add(kv(labels[4], parts.join(_dim('  ·  '))));
      }
      final caps = service['capabilities'];
      if (caps is List && caps.isNotEmpty) {
        body.addAll(
          _chipLines(
            labels[5],
            [for (final c in caps) c.toString()],
            labelW,
            target,
          ),
        );
      }
    }

    _panel(title: '${_cyan('♪')} ${_bold(name)}', body: body, pad: pad);
  }

  /// 曲库统计面板（`library-stats`）：曲目数 / 占用空间 / 总时长。
  void libraryStats(Map<Object?, Object?> map) {
    const pad = 2;
    final labels = [
      l10n.mcpShellLblTracks,
      l10n.mcpShellLblSize,
      l10n.mcpShellLblDuration,
    ];
    final labelW = labels.map(_displayWidth).reduce(math.max);
    String kv(String label, String value) =>
        '${_dim(_fit(label, labelW))}  $value';

    final body = <String>[];
    if (map['tracks'] != null) {
      body.add(kv(labels[0], _bold(map['tracks'].toString())));
    }
    final size = map['totalSizeBytes'];
    if (size is num) body.add(kv(labels[1], _formatBytes(size.toInt())));
    final duration = map['totalDurationMs'];
    if (duration is num) {
      body.add(kv(labels[2], _formatDuration(duration.toInt())));
    }
    if (body.isEmpty) body.add(_dim('· ${l10n.mcpShellLblEmpty}'));

    _panel(
      title: '${_cyan('♪')} ${_bold(l10n.mcpShellLblLibrary)}',
      body: body,
      pad: pad,
    );
  }

  /// 搜索头部 + 结果表（`search`）。`total` 并入头部，表格不再重复计数。
  void searchResult(Map<Object?, Object?> map) {
    final segments = <String>[
      if (map['source'] != null) _cyan(_bold(map['source'].toString())),
      if (map['query'] != null) '“${_bold(map['query'].toString())}”',
      if (map['page'] != null) _dim('${l10n.mcpShellLblPage} ${map['page']}'),
      if (map['total'] != null)
        _dim('${l10n.mcpShellLblTotal} ${map['total']}'),
    ];
    _write('  ${_dim(l10n.mcpShellLblSearch)}  ${segments.join(_dim('  ·  '))}');
    final tracks = map['tracks'];
    if (tracks is List) this.tracks(tracks);
  }

  /// 队列头部（索引/循环/随机）+ 结果表（`queue`）。
  void queueResult(Map<Object?, Object?> map) {
    final list = map['tracks'] is List
        ? map['tracks'] as List
        : const <Object?>[];
    final index = map['index'];
    final segments = <String>[
      if (index is num && list.isNotEmpty)
        _dim('${l10n.mcpShellLblIndex} ${index + 1}/${list.length}'),
      if (map['repeatMode'] != null)
        _dim('${l10n.mcpShellLblRepeat} ${map['repeatMode']}'),
      _dim(
        map['shuffle'] == true
            ? l10n.mcpShellLblShuffleOn
            : l10n.mcpShellLblShuffleOff,
      ),
    ];
    _write('  ${_dim(l10n.mcpShellLblQueue)}  ${segments.join(_dim('  ·  '))}');
    tracks(list);
  }

  /// 某音源「我喜欢的」列表头部 + 结果表（`list-liked`）。
  void likedResult(Map<Object?, Object?> map) {
    final total = map['total'];
    _write(
      '  ${_dim(l10n.mcpShellLblLiked)}  '
      '${_cyan(_bold(map['source']?.toString() ?? ''))}'
      '${total == null ? '' : _dim('  ·  ${l10n.mcpShellLblTotal} $total')}',
    );
    final tracks = map['tracks'];
    if (tracks is List) this.tracks(tracks);
  }

  /// 动作类返回值（`{ok:true, ...}` / 收藏状态）：绿色勾号 + 可读摘要。
  void confirm(Map<Object?, Object?> map) {
    final ref = map['ref'];
    if (map['liked'] is bool && map['ok'] != true) {
      final liked = map['liked'] == true;
      _write(
        '  ${liked ? _red('♥') : _dim('♡')}  '
        '${liked ? l10n.mcpShellLblLiked : l10n.mcpShellLblNotLiked}'
        '${ref == null ? '' : '  ${_dim(ref.toString())}'}',
      );
      return;
    }
    if (map['mode'] == 'endOfTrack') {
      _write(
        '  ${_green('✓')}  ${_dim(l10n.mcpShellLblSleep)}  '
        '${l10n.mcpShellLblEndOfTrack}',
      );
      return;
    }
    if (map['mode'] == 'duration' && map['minutes'] is num) {
      _write(
        '  ${_green('✓')}  ${_dim(l10n.mcpShellLblSleep)}  '
        '${map['minutes']}m',
      );
      return;
    }

    final parts = <String>[];
    map.forEach((k, v) {
      final key = k.toString();
      if (key == 'ok' || key == 'startIndex' || v == null) return;
      switch (key) {
        case 'volume':
          if (v is num) parts.add('${l10n.mcpShellLblVolume} ${(v * 100).round()}%');
        case 'repeatMode':
          parts.add('${l10n.mcpShellLblRepeat} $v');
        case 'shuffle':
          parts.add(
            v == true
                ? l10n.mcpShellLblShuffleOn
                : l10n.mcpShellLblShuffleOff,
          );
        case 'quality':
          parts.add('${l10n.mcpShellLblQuality} $v');
        case 'ref':
          parts.add('${l10n.mcpShellLblNowPlaying} $v');
        case 'taskId':
          parts.add('${l10n.mcpShellLblTask} $v');
        case 'liked':
          parts.add(
            v == true ? l10n.mcpShellLblLiked : l10n.mcpShellLblUnliked,
          );
        case 'count':
          parts.add(
            map['position'] != null
                ? '${l10n.mcpShellLblQueued} $v'
                : '${l10n.mcpShellLblCount} $v',
          );
        case 'position':
          parts.add('→ $v');
        case 'mode':
          parts.add('${l10n.mcpShellLblTheme} $v');
        default:
          parts.add('$key $v');
      }
    });
    final detail = parts.isEmpty
        ? l10n.mcpShellLblOk
        : parts.join(_dim('  ·  '));
    _write('  ${_green('✓')}  $detail');
  }

  // ── 列表 ──────────────────────────────────────────────────────

  /// 曲目/队列/曲库/历史的对齐表格。
  ///
  /// [total] 非空时先打印 dim 计数；[tag] 指定附带的额外列（如历史 `playedAt`），
  /// [extraHeader] 为其表头，[fmtExtra] 用于把原始值格式化为可读文本（如相对时间）。
  /// 队列项带 `isCurrent` 时用绿色 `▶` 取代序号。
  void tracks(
    List<Object?> list, {
    Object? total,
    String? tag,
    String? extraHeader,
    String Function(Object? raw)? fmtExtra,
  }) {
    final rows = <_TrackRow>[];
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      if (item is! Map) continue;
      final m = item.cast<Object?, Object?>();
      final rawExtra = tag == null ? null : m[tag];
      rows.add(
        _TrackRow(
          index: '${i + 1}',
          title: (m['title'] ?? '').toString(),
          artist: _artists(m),
          ref: (m['ref'] ?? '').toString(),
          extra: tag == null
              ? null
              : (fmtExtra == null
                    ? (rawExtra ?? '').toString()
                    : fmtExtra(rawExtra)),
          current: m['isCurrent'] == true,
        ),
      );
    }

    if (total != null) {
      _write(_dim('  ${l10n.mcpShellLblTotal} $total'));
    }
    if (rows.isEmpty) {
      _write(_dim('  · ${l10n.mcpShellLblEmpty}'));
      return;
    }

    final idxW = math.max(
      2,
      rows.map((r) => _displayWidth(r.index)).fold(1, math.max),
    );
    // ref 优先保证完整：不设上限，只在窗口实在放不下时才收缩/丢弃。
    final refW = _colWidth(rows.map((r) => r.ref), 1 << 20, min: 3);
    final artistW = _colWidth(rows.map((r) => r.artist), 26, min: 6);
    final extraW = _colWidth(
      rows.where((r) => r.extra != null).map((r) => r.extra!),
      24,
    );
    var titleW = _colWidth(rows.map((r) => r.title), 48, min: 5);
    var shrunkArtist = artistW;
    var shrunkRef = refW;
    var shrunkExtra = extraW;

    const margin = 2;
    const gap = 2;
    final available = math.max(1, columns - margin);
    int extent() =>
        margin +
        idxW +
        (titleW > 0 ? gap + titleW : 0) +
        (shrunkArtist > 0 ? gap + shrunkArtist : 0) +
        (shrunkRef > 0 ? gap + shrunkRef : 0) +
        (shrunkExtra > 0 ? gap + shrunkExtra : 0);

    // 收缩优先级：额外列 → 标题 → 歌手 → 丢歌手 → 标题让到底；**ref 最后才动**。
    while (extent() > available) {
      if (shrunkExtra > 0) {
        shrunkExtra = 0;
      } else if (titleW > 8) {
        titleW--;
      } else if (shrunkArtist > 6) {
        shrunkArtist--;
      } else if (shrunkArtist > 0) {
        shrunkArtist = 0;
      } else if (titleW > 1) {
        titleW--;
      } else {
        break;
      }
    }
    // 标题/歌手已让到极限仍放不下，才收缩 ref；再不行才丢弃（窗口极小）。
    while (extent() > available && shrunkRef > 4) {
      shrunkRef--;
    }
    if (extent() > available) shrunkRef = 0;

    final header = StringBuffer(' ' * margin)
      ..write(_dim('#'.padLeft(idxW)))
      ..write(
        titleW > 0
            ? ' ' * gap + _dim(_fit(l10n.mcpShellLblColTitle, titleW))
            : '',
      )
      ..write(
        shrunkArtist > 0
            ? ' ' * gap + _dim(_fit(l10n.mcpShellLblColArtist, shrunkArtist))
            : '',
      )
      ..write(
        shrunkRef > 0
            ? ' ' * gap + _dim(_fit(l10n.mcpShellLblColRef, shrunkRef))
            : '',
      )
      ..write(
        shrunkExtra > 0
            ? ' ' * gap +
                  _dim(
                    _fit(
                      extraHeader ?? l10n.mcpShellLblColWhen,
                      shrunkExtra,
                    ),
                  )
            : '',
      );
    _write(header.toString());

    for (final r in rows) {
      final buf = StringBuffer(' ' * margin);
      if (r.current) {
        buf
          ..write(_green('▶'))
          ..write(' ' * math.max(0, idxW - 1));
      } else {
        buf.write(_dim(r.index.padLeft(idxW)));
      }
      if (titleW > 0) {
        buf
          ..write(' ' * gap)
          ..write(_fit(r.title, titleW, style: r.current ? _green : null));
      }
      if (shrunkArtist > 0) {
        buf
          ..write(' ' * gap)
          ..write(_fit(r.artist, shrunkArtist, style: _dim));
      }
      if (shrunkRef > 0) {
        buf
          ..write(' ' * gap)
          ..write(_fit(r.ref, shrunkRef, style: _cyan));
      }
      if (shrunkExtra > 0 && r.extra != null) {
        buf
          ..write(' ' * gap)
          ..write(_fit(r.extra!, shrunkExtra, style: _dim));
      }
      _write(buf.toString());
    }
  }

  /// 跨音源搜索：按源分组，组头带计数徽标。
  void searchAll(Map<Object?, Object?> map) {
    final query = map['query'];
    if (query != null) {
      _write('  ${_dim(l10n.mcpShellLblQuery)}  ${_bold(query.toString())}');
    }
    final results = map['results'];
    if (results is! List) return;
    for (final item in results) {
      if (item is! Map) continue;
      final m = item.cast<Object?, Object?>();
      final source = (m['source'] ?? '?').toString();
      final error = m['error'];
      if (error != null) {
        _write(
          '  ${_dim('──')} ${_red(_bold(source))}  '
          '${_red('${l10n.mcpShellLblError}: $error')}',
        );
        continue;
      }
      final total = m['total'];
      final more = m['hasMore'] == true ? '+' : '';
      _section(source, total == null ? '' : '$total$more');
      final tracks = m['tracks'];
      if (tracks is List) this.tracks(tracks);
    }
  }

  /// 下载任务：状态图标 + 进度条 + 百分比 + 曲目。
  void downloadTasks(List<Object?> list, {Object? total}) {
    if (total != null) {
      _write(_dim('  ${l10n.mcpShellLblTotal} $total'));
    }
    if (list.isEmpty) {
      _write(_dim('  · ${l10n.mcpShellLblEmpty}'));
      return;
    }
    for (final item in list) {
      if (item is! Map) continue;
      final m = item.cast<Object?, Object?>();
      final status = (m['status'] ?? '-').toString();
      final (icon, style) = _downloadState(status);
      final progress = m['progress'];
      final ratio = progress is num
          ? progress.toDouble().clamp(0.0, 1.0)
          : 0.0;
      final pct = progress is num
          ? '${(progress * 100).toStringAsFixed(1)}%'
          : '-';
      final artist = (m['artist'] ?? '').toString();
      final taskId = (m['taskId'] ?? '').toString();
      final buf = StringBuffer('  ')
        ..write(style(icon))
        ..write('  ')
        ..write(style(_padRight(status, 11)))
        ..write('  ')
        ..write(_bar(ratio, 16))
        ..write('  ')
        ..write(_dim(_padRight(pct, 6)))
        ..write('  ')
        ..write(_bold((m['title'] ?? '').toString()));
      if (artist.isNotEmpty) buf.write('  ${_dim(artist)}');
      if (taskId.isNotEmpty) buf.write('  ${_dim(taskId)}');
      _write(buf.toString());
    }
  }

  /// 歌词：时间戳 + 正文（译文另起一行）。
  void lyrics(List<Object?> list) {
    for (final item in list) {
      if (item is! Map) continue;
      final m = item.cast<Object?, Object?>();
      final time = _formatMs(m['timeMs']);
      final text = (m['text'] ?? '').toString();
      _write('  ${_dim(time)}  $text');
      final translation = m['translation'];
      if (translation != null && translation.toString().isNotEmpty) {
        _write('${' ' * 9}${_dim(_italic(translation.toString()))}');
      }
    }
  }

  /// 工具目录：名称 / 能力 / 标题 三列。
  void tools(List<Object?> list) {
    final rows = <(String, String, String)>[];
    for (final item in list) {
      if (item is! Map) continue;
      rows.add((
        (item['name'] ?? '').toString(),
        (item['capability'] ?? '').toString(),
        (item['title'] ?? '').toString(),
      ));
    }
    if (rows.isEmpty) return;
    final nameW = math.min(
      28,
      rows
          .map((r) => _displayWidth(r.$1))
          .fold(_displayWidth(l10n.mcpShellLblToolName), math.max),
    );
    final capW = math.min(
      14,
      rows
          .map((r) => _displayWidth(r.$2))
          .fold(_displayWidth(l10n.mcpShellLblToolCap), math.max),
    );
    _write(
      '  ${_dim(_padRight(l10n.mcpShellLblToolName, nameW))}  '
      '${_dim(_padRight(l10n.mcpShellLblToolCap, capW))}  '
      '${_dim(l10n.mcpShellLblToolTitle)}',
    );
    for (final (name, capability, title) in rows) {
      _write(
        '  ${_cyan(_fit(name, nameW))}  '
        '${_dim(_fit(capability, capW))}  $title',
      );
    }
  }

  /// 音源列表：登录状态圆点 + 音源 + 标签。
  void sources(List<Object?> list) {
    final rows = <(String, String, bool)>[];
    for (final item in list) {
      if (item is! Map) continue;
      rows.add((
        (item['source'] ?? '').toString(),
        (item['label'] ?? '').toString(),
        item['loggedIn'] == true,
      ));
    }
    if (rows.isEmpty) return;
    final labelW = math.min(
      20,
      rows.map((r) => _displayWidth(r.$2)).fold(5, math.max),
    );
    final sourceW = math.min(
      16,
      rows.map((r) => _displayWidth(r.$1)).fold(6, math.max),
    );
    for (final (source, label, loggedIn) in rows) {
      final dot = loggedIn ? _green('●') : _dim('○');
      final state = loggedIn
          ? _dim(l10n.mcpShellLblLoggedIn)
          : _dim(l10n.mcpShellLblLoggedOut);
      _write(
        '  $dot  ${_cyan(_fit(source, sourceW))}  '
        '${_fit(label, labelW)}  $state',
      );
    }
  }

  // ── 面板/进度条 ───────────────────────────────────────────────

  /// 圆角面板；[inner] 指定两条竖线之间的宽度（省略则由内容自适应）。
  void _panel({
    required String title,
    required List<String> body,
    int pad = 2,
    int? inner,
  }) {
    final cap = math.max(8, columns - 2);
    var t = title;
    var need = body
        .map((l) => _displayWidth(l) + pad * 2)
        .fold<int>(0, math.max);
    need = math.max(need, _displayWidth(t) + 3);
    final boxInner = (inner ?? need).clamp(math.min(20, cap), cap).toInt();
    if (_displayWidth(t) + 3 > boxInner) {
      t = _truncate(t, math.max(1, boxInner - 3));
    }
    final contentW = boxInner - pad * 2;
    final dashes = math.max(0, boxInner - _displayWidth(t) - 3);
    _write('${_dim('╭─')} $t ${_dim('${'─' * dashes}╮')}');
    for (final line in body) {
      final l = _displayWidth(line) > contentW ? _truncate(line, contentW) : line;
      final fill = math.max(0, contentW - _displayWidth(l));
      _write(
        '${_dim('│')}${' ' * pad}$l${' ' * fill}${' ' * pad}${_dim('│')}',
      );
    }
    _write(_dim('╰${'─' * boxInner}╯'));
  }

  /// 组头：`── source ────── 12+`（源名青色，破折号与徽标 dim）。
  void _section(String title, String badge) {
    final badgePart = badge.isEmpty ? '' : ' ${_dim(badge)}';
    final used =
        6 +
        _displayWidth(title) +
        (badge.isEmpty ? 0 : 1 + _displayWidth(badge));
    final fill = math.max(1, columns - used);
    _write(
      '  ${_dim('──')} ${_cyan(_bold(title))} '
      '${_dim('─' * fill)}$badgePart',
    );
  }

  /// 把 [items] 渲染成青色标签并按 [maxWidth] 折行；首行带 [label]，续行缩进对齐。
  List<String> _chipLines(
    String label,
    List<String> items,
    int labelW,
    int maxWidth,
  ) {
    final prefix = '${_dim(_fit(label, labelW))}  ';
    final indent = ' ' * (labelW + 2);
    final lines = <String>[];
    var line = StringBuffer();
    var lineWidth = 0;
    var linePrefix = prefix;
    for (final item in items) {
      final chipW = _displayWidth(item);
      final needed = lineWidth == 0 ? chipW : lineWidth + 2 + chipW;
      if (lineWidth > 0 && labelW + 2 + needed > maxWidth) {
        lines.add('$linePrefix$line');
        line = StringBuffer();
        lineWidth = 0;
        linePrefix = indent;
      }
      if (lineWidth > 0) {
        line.write('  ');
        lineWidth += 2;
      }
      line.write(_cyan(item));
      lineWidth += chipW;
    }
    if (line.isNotEmpty) lines.add('$linePrefix$line');
    return lines;
  }

  /// 进度条：已播放部分青色实心，其余 dim 点阵；宽度不足返回空串。
  String _bar(double ratio, int width) {
    if (width < 4) return '';
    final filled = (ratio * width).round().clamp(0, width);
    final parts = <String>[
      if (filled > 0) _cyan('█' * filled),
      if (width - filled > 0) _dim('░' * (width - filled)),
    ];
    return parts.join();
  }

  static double _ratio(Object? positionMs, Object? durationMs) {
    if (positionMs is! num || durationMs is! num || durationMs <= 0) return 0;
    return (positionMs / durationMs).clamp(0.0, 1.0);
  }

  (String, String Function(String)) _downloadState(String status) {
    final s = status.toLowerCase();
    if (s.contains('fail') || s.contains('error')) return ('✗', _red);
    if (s.contains('done') || s.contains('complet') || s.contains('success')) {
      return ('✓', _green);
    }
    if (s.contains('download') ||
        s.contains('active') ||
        s.contains('running')) {
      return ('↓', _cyan);
    }
    if (s.contains('pause') ||
        s.contains('wait') ||
        s.contains('queue') ||
        s.contains('pending')) {
      return ('◌', _yellow);
    }
    if (s.contains('cancel')) return ('⊗', _dim);
    return ('·', _dim);
  }

  // ── 字段/宽度辅助 ─────────────────────────────────────────────

  static String _artists(Map item) {
    final artists = item['artists'];
    if (artists is List) {
      return artists
          .where((a) => a != null)
          .map((a) => a.toString())
          .join(' / ');
    }
    final artist = item['artist'];
    return artist == null ? '' : artist.toString();
  }

  static String _formatMs(Object? ms) {
    if (ms is! num) return '--:--';
    final total = ms.toInt();
    final seconds = total ~/ 1000;
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// 一列的自然宽度（全空则为 0），下限 [min]（容下表头）、上限 [cap]。
  static int _colWidth(Iterable<String> cells, int cap, {int min = 0}) {
    var w = 0;
    for (final c in cells) {
      final cw = _displayWidth(c);
      if (cw > w) w = cw;
    }
    if (w == 0) return 0;
    return math.min(math.max(w, min), cap);
  }

  /// 人类可读字节数（不足 1 KiB 显示 B，最多两位小数）。
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  }

  /// 人类可读时长（h/m/s，省略为 0 的高位）。
  static String _formatDuration(int ms) {
    final total = ms ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final parts = <String>[
      if (h > 0) '${h}h',
      if (m > 0) '${m}m',
      if (s > 0 || (h == 0 && m == 0)) '${s}s',
    ];
    return parts.join(' ');
  }

  /// 历史播放时刻：相对时间（近期）或日期（久远）。
  String relativeTime(Object? ms) {
    if (ms is! num || ms <= 0) return '';
    final value = ms.toInt();
    final diff = DateTime.now().millisecondsSinceEpoch - value;
    if (diff < 0) return 'now';
    final seconds = diff ~/ 1000;
    if (seconds < 60) return 'just now';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '${minutes}m ago';
    final hours = minutes ~/ 60;
    if (hours < 24) return '${hours}h ago';
    final days = hours ~/ 24;
    if (days < 30) return '${days}d ago';
    final dt = DateTime.fromMillisecondsSinceEpoch(value);
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    return '${dt.year}-$mm-$dd';
  }
}

/// 曲目表格的一行。
class _TrackRow {
  const _TrackRow({
    required this.index,
    required this.title,
    required this.artist,
    required this.ref,
    required this.extra,
    required this.current,
  });

  final String index;
  final String title;
  final String artist;
  final String ref;
  final String? extra;
  final bool current;
}

// ── 显示宽度（CJK 感知） ────────────────────────────────────────

/// 截断到 [width] 显示列（保留 ANSI 序列），超出以 `…` 收尾。
String _truncate(String s, int width) {
  if (_displayWidth(s) <= width) return s;
  if (width <= 1) return '…';
  final buf = StringBuffer();
  var w = 0;
  var i = 0;
  while (i < s.length) {
    if (s.codeUnitAt(i) == 0x1b) {
      final m = _sgr.matchAsPrefix(s, i);
      if (m != null) {
        buf.write(m.group(0));
        i = m.end;
        continue;
      }
    }
    final (rune, next) = _runeAt(s, i);
    final rw = _runeWidth(rune);
    if (w + rw > width - 1) break;
    buf.writeCharCode(rune);
    w += rw;
    i = next;
  }
  buf.write('…');
  // 截断可能切断 ANSI 序列（丢掉其复位），补一个复位避免样式外溢。
  if (s.contains('\x1b')) buf.write('\x1b[0m');
  return buf.toString();
}

/// 右侧补空格到 [width] 显示列（已够宽则原样返回）。
String _padRight(String s, int width) {
  final w = _displayWidth(s);
  if (w >= width) return s;
  return '$s${' ' * (width - w)}';
}

/// 截断 + 补齐到 [width]，可选样式在补齐后包裹。
String _fit(String text, int width, {String Function(String)? style}) {
  if (width <= 0) return '';
  var t = text;
  if (_displayWidth(t) > width) t = _truncate(t, width);
  t = _padRight(t, width);
  return style == null ? t : style(t);
}

/// 读取 [i] 处的 Unicode 码点，返回 (码点, 下一索引)；代理对按 2 个 code unit 前进。
(int, int) _runeAt(String s, int i) {
  final cu = s.codeUnitAt(i);
  if (cu >= 0xd800 && cu <= 0xdbff && i + 1 < s.length) {
    final lo = s.codeUnitAt(i + 1);
    if (lo >= 0xdc00 && lo <= 0xdfff) {
      return (0x10000 + ((cu - 0xd800) << 10) + (lo - 0xdc00), i + 2);
    }
  }
  return (cu, i + 1);
}

/// 字符串显示列数（剔除 ANSI，East Asian 宽字符按 2）。
int _displayWidth(String s) {
  if (s.isEmpty) return 0;
  final plain = s.contains('\x1b') ? s.replaceAll(_sgr, '') : s;
  var w = 0;
  for (final rune in plain.runes) {
    w += _runeWidth(rune);
  }
  return w;
}

/// 单个码点的显示列宽：组合符/连接符/零宽字符为 0，East Asian 宽字符为 2。
int _runeWidth(int rune) {
  if (rune == 0) return 0;
  // 控制字符（不含制表符视为 0；我们输出中不使用 tab）。
  if (rune < 0x20 || (rune >= 0x7f && rune < 0xa0)) return 0;
  // 组合符号 / 变体选择符 / 零宽连接符。
  if ((rune >= 0x0300 && rune <= 0x036f) ||
      (rune >= 0x1ab0 && rune <= 0x1aff) ||
      (rune >= 0x1dc0 && rune <= 0x1dff) ||
      (rune >= 0x20d0 && rune <= 0x20ff) ||
      (rune >= 0xfe00 && rune <= 0xfe0f) ||
      (rune >= 0xfe20 && rune <= 0xfe2f) ||
      rune == 0x200b ||
      rune == 0x200c ||
      rune == 0x200d ||
      rune == 0x2060 ||
      rune == 0xfeff) {
    return 0;
  }
  // East Asian Wide / Fullwidth。
  if ((rune >= 0x1100 && rune <= 0x115f) ||
      (rune >= 0x2e80 && rune <= 0x303e) ||
      (rune >= 0x3041 && rune <= 0x33ff) ||
      (rune >= 0x3400 && rune <= 0x4dbf) ||
      (rune >= 0x4e00 && rune <= 0x9fff) ||
      (rune >= 0xa000 && rune <= 0xa4cf) ||
      (rune >= 0xac00 && rune <= 0xd7a3) ||
      (rune >= 0xf900 && rune <= 0xfaff) ||
      (rune >= 0xfe10 && rune <= 0xfe19) ||
      (rune >= 0xfe30 && rune <= 0xfe6f) ||
      (rune >= 0xff00 && rune <= 0xff60) ||
      (rune >= 0xffe0 && rune <= 0xffe6) ||
      (rune >= 0x1f300 && rune <= 0x1faff) ||
      (rune >= 0x20000 && rune <= 0x3fffd)) {
    return 2;
  }
  return 1;
}
