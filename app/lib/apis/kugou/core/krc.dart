/// KRC 歌词解密与格式化（Dart 移植）——对齐 apis/kugou/core/krc.ts。
///
/// 加密：base64(content) 去头 4 字节 → 与 16 字节定 key 循环 XOR → zlib inflate → UTF-8 文本。
/// 输出 4 种歌词：lrc（行级）/ krc（逐字 LX 格式）/ trans / roma。
/// key 与解析逻辑来源：lx-music-desktop/src/common/utils/lyricUtils/kg.js。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'config.dart';

const List<int> _krcKey = [
  0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
];

/// base64 → XOR → inflate → 文本
String _decryptKrc(String base64) {
  if (base64.isEmpty) throw StateError('empty krc content');
  final raw = base64Decode(base64);
  final buf = Uint8List.fromList(raw.sublist(4));
  for (var i = 0; i < buf.length; i++) {
    buf[i] ^= _krcKey[i % 16];
  }
  final out = zlib.decode(buf);
  return utf8.decode(out);
}

/// KRC 头部元数据行（[ar:]/[ti:]/[al:]/[by:]/[hash:]/[sign:]/[qq:]/
/// [total:]/[offset:]/[id:$...]）——非歌词正文，整体移除（对齐 lx-music
/// kg.js parseKrc 的元数据清理）。此前仅移除 [id:$] 行，其余 9 行残留
/// 进 lrc 文本污染行级解析。
// 注意 [id:$00000000] 的值后**直接是** ']'（无冒号），其余元数据行
// 为 [key:value]（有冒号）——故冒号部分必须可选，否则 id 行残留。
final RegExp _metaLineReg = RegExp(
    r'^\[(?:id:\$\w+|ar|ti|al|by|hash|sign|qq|total|offset)(?::[^\]]*)?\](?:\r?\n)?',
    multiLine: true);
final RegExp _languageReg = RegExp(r'\[language:([\w=\\/+]+)\]');
final RegExp _languageLineReg = RegExp(r'\[language:[\w=\\/+]+\]\n');
final RegExp _lineTimeReg = RegExp(r'\[((\d+),\d+)\].*', multiLine: true);
final RegExp _lineTimeEachReg = RegExp(r'\[((\d+),\d+)\].*');
final RegExp _wordTagReg = RegExp(r'<(\d+,\d+),\d+>');

/// 毫秒 → `MM:SS.xxx`（毫秒段补零到 3 位，与 services/kugou 版一致；
/// 此前不补零输出 `00:00.0`，两套解析器时间标签格式不统一）
String _msToTimeTag(int ms) {
  final m = (ms ~/ 60000).toString().padLeft(2, '0');
  final s = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
  final x = (ms % 1000).toString().padLeft(3, '0');
  return '$m:$s.$x';
}

class KrcParsed {
  const KrcParsed({required this.lrc, required this.krc, required this.trans, required this.roma});

  final String lrc;
  final String krc;
  final String trans;
  final String roma;
}

/// 解析解密后的 KRC 文本 → 四种歌词
KrcParsed _parseKrc(String raw) {
  var text = raw.replaceAll('\r', '');
  text = text.replaceAll(_metaLineReg, '');

  // 翻译 & 罗马音以 [language:base64(json)] 整体嵌入
  List<String>? transLines;
  List<String>? romaLines;
  final langMatch = _languageReg.firstMatch(text);
  if (langMatch != null) {
    text = text.replaceFirst(_languageLineReg, '');
    try {
      final json = jsonDecode(utf8.decode(base64Decode(langMatch.group(1)!))) as Map<String, dynamic>;
      for (final item in (json['content'] as List? ?? const [])) {
        final it = item as Map;
        final lines = (it['lyricContent'] as List).map((arr) => (arr as List).join('')).toList();
        if (it['type'] == 0) {
          romaLines = lines;
        } else if (it['type'] == 1) {
          transLines = lines;
        }
      }
    } catch (_) {
      // 译文解析失败不影响主歌词
    }
  }

  // 逐行替换行首时间标签：把 [start_ms,dur_ms] 改成 [MM:SS.xxx]
  // 同时按行索引同步给翻译/罗马音补上时间头
  var idx = 0;
  var krcBody = text.replaceAllMapped(_lineTimeReg, (match) {
    final line = match.group(0)!;
    final each = _lineTimeEachReg.firstMatch(line);
    if (each == null) return line;
    final startMs = int.parse(each.group(2)!);
    final timeTag = _msToTimeTag(startMs);
    if (romaLines != null && idx < romaLines.length) {
      romaLines[idx] = '[$timeTag]${romaLines[idx]}';
    }
    if (transLines != null && idx < transLines.length) {
      transLines[idx] = '[$timeTag]${transLines[idx]}';
    }
    idx++;
    return line.replaceFirst(each.group(1)!, timeTag);
  });

  // 字级时间标签 <offset,dur,0> → <offset,dur>（去除末尾的 0）
  krcBody = krcBody.replaceAllMapped(_wordTagReg, (m) => '<${m.group(1)}>');
  final krc = kgDecodeName(krcBody);
  final lrc = krc.replaceAll(RegExp(r'<\d+,\d+>'), '');

  return KrcParsed(
    lrc: lrc,
    krc: krc,
    trans: kgDecodeName(transLines?.join('\n') ?? ''),
    roma: kgDecodeName(romaLines?.join('\n') ?? ''),
  );
}

/// 解密并解析一段 KRC base64 内容
KrcParsed kgDecodeKrc(String base64Content) => _parseKrc(_decryptKrc(base64Content));
