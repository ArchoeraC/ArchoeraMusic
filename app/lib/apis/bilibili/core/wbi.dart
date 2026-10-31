// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili WBI 签名（纯函数，无网络）。
///
/// 协议步骤：
/// 1. 从 `/x/web-interface/nav` 的 `wbi_img.img_url` / `sub_url` 取 32 位
///    `img_key` / `sub_key`；
/// 2. 两键拼接后按固定 32 位置换表取 salt；
/// 3. 参数加入 `wts`（秒）后按键排序，值去除 `!'()*` 并百分号编码；
/// 4. `md5(query + salt)` 得 `w_rid`，追加到 query。
///
/// 与 B 站公开的 WBI 规则一致；实现独立，不复用其它客户端代码。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// WBI salt 的固定置换位置。
const List<int> _wbiPositions = [
  46,
  47,
  18,
  2,
  53,
  8,
  23,
  32,
  15,
  50,
  10,
  31,
  58,
  3,
  45,
  35,
  27,
  43,
  5,
  49,
  33,
  9,
  42,
  19,
  29,
  28,
  14,
  39,
  12,
  38,
  41,
  13,
];

final RegExp _wbiKeyPattern = RegExp(r'^[a-fA-F0-9]{32}$');

/// 由 `img_key` + `sub_key` 生成 32 位 mixin key；非法 key 返回 null。
String? bilibiliWbiMixinKey(String imageKey, String subKey) {
  if (!_wbiKeyPattern.hasMatch(imageKey) || !_wbiKeyPattern.hasMatch(subKey)) {
    return null;
  }
  final raw = '$imageKey$subKey';
  final buffer = StringBuffer();
  for (final position in _wbiPositions) {
    buffer.write(raw[position]);
  }
  return buffer.toString();
}

/// 生成带 `wts` / `w_rid` 的 query 字符串。
///
/// [timestamp] 为 Unix 秒。返回 null 表示 key 非法（调用方应刷新 WBI key）。
String? bilibiliWbiQuery({
  required Map<String, String> params,
  required String imageKey,
  required String subKey,
  required int timestamp,
}) {
  final mixinKey = bilibiliWbiMixinKey(imageKey, subKey);
  if (mixinKey == null || timestamp < 0) return null;

  final all = <String, String>{...params, 'wts': '$timestamp'};
  final keys = all.keys.toList()..sort();
  final buffer = StringBuffer();
  for (final key in keys) {
    if (buffer.isNotEmpty) buffer.write('&');
    buffer.write(Uri.encodeComponent(key));
    buffer.write('=');
    buffer.write(Uri.encodeComponent(_cleanWbiValue(all[key] ?? '')));
  }
  final query = buffer.toString();
  final digest = md5.convert(utf8.encode('$query$mixinKey')).toString();
  return '$query&w_rid=$digest';
}

/// 值中的 `!'()*` 在签名前必须移除（B 站 WBI 规则）。
String _cleanWbiValue(String value) => value.replaceAll(RegExp(r"[!'()*]"), '');
