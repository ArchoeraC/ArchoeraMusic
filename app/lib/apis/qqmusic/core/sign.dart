// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QQ 桌面端请求签名 `zzcSign`——移植自 baka-plugins `plugins/qq.js:315`。
///
/// 桌面协议入口 `u.y.qq.com/cgi-bin/musics.fcg` 要求对**即将发送的 JSON 串**
/// 计算 `?sign=`：
/// 1. 取该串的 SHA1（大写十六进制）；
/// 2. `part1`/`part2` 按固定下标从摘要取字（越界下标按 JS `Array.join` 语义
///    **丢弃**，见 `qq.js:301` 的 `pickHashByIndexes`）；
/// 3. `part3` 把摘要每 2 个十六进制字符转字节，与固定常量逐位 XOR，再 base64
///    并去掉 `/ + =`；
/// 4. 拼成 `zzc{part1}{part3}{part2}` 后**整体小写**。
///
/// 签名只覆盖请求体（不含 URL/头），故调用方必须保证「参与签名的字符串」与
/// 「实际发送的字节」完全一致（同一份 `jsonEncode` 结果，字段顺序需稳定）。
///
/// 来源：`baka-plugins`（无许可证，仅作协议事实参考，未复制其代码表达）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// SHA1 摘要中参与 `part1` 的字符下标（对齐 `qq.js` `SIGN_PART_1_INDEXES`）。
const List<int> _signPart1Indexes = [23, 14, 6, 36, 16, 40, 7, 19];

/// SHA1 摘要中参与 `part2` 的字符下标（对齐 `qq.js` `SIGN_PART_2_INDEXES`）。
const List<int> _signPart2Indexes = [16, 1, 32, 12, 19, 27, 8, 5];

/// `part3` 的 XOR 混淆常量（对齐 `qq.js` `SIGN_SCRAMBLE_VALUES`，20 字节）。
const List<int> _signScrambleValues = [
  89, 39, 179, 150, 218, 82, 58, 252, 177, 52, //
  186, 123, 120, 64, 242, 133, 143, 161, 121, 179,
];

/// 计算桌面协议签名（返回值形如 `zzcq3f...`，含 `zzc` 前缀、全小写）。
String qmZzcSign(String text) {
  final hash = sha1.convert(utf8.encode(text)).toString().toUpperCase();
  final part1 = _pickHashByIndexes(hash, _signPart1Indexes);
  final part2 = _pickHashByIndexes(hash, _signPart2Indexes);
  final scrambled = List<int>.generate(_signScrambleValues.length, (i) {
    final byte = (_hexAt(hash, i * 2) << 4) | _hexAt(hash, i * 2 + 1);
    return byte ^ _signScrambleValues[i];
  });
  final part3 = base64.encode(scrambled).replaceAll(RegExp(r'[/+=]'), '');
  return 'zzc$part1$part3$part2'.toLowerCase();
}

/// 按下标从摘要取字并拼接；越界下标直接跳过（对齐 JS `hash[idx]` 为
/// `undefined` 时 `join` 归为空串的行为）。
String _pickHashByIndexes(String hash, List<int> indexes) {
  final buf = StringBuffer();
  for (final i in indexes) {
    if (i >= 0 && i < hash.length) buf.write(hash[i]);
  }
  return buf.toString();
}

/// 取摘要第 [i] 位的十六进制值；越界/非法返回 0（对齐 JS `parseInt('',16)=NaN`
/// 参与 XOR 时按 0 处理）。
int _hexAt(String hash, int i) {
  if (i < 0 || i >= hash.length) return 0;
  return int.tryParse(hash[i], radix: 16) ?? 0;
}
