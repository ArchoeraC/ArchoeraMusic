// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 字符脚本分类（**与原生侧 `app/core/shared/text/ScriptRanges.cs` 逐区间一致**）。
///
/// 为什么要有这一层：索引期分词按脚本决定「整词」还是「bigram + unigram」，查询侧必须用
/// **同一套判断**才能生成同构表达式（否则查询切分与索引切分漂移，召回静默变差）。
/// 详见设计文档 `docs/local-search-index-plan.md` §4.1（含真实日文曲库实测）。
///
/// 两类语义要分清：
/// - [isCjk]：**汉字**（表意）——只有汉字才有拼音 / 首字母，拼音高亮只认它；
/// - [isIndexedScript]：**需要子串索引的脚本** = 汉字 + 假名 + 谚文（子串 / 前缀 / 词组可命中）。
library;

/// 汉字：CJK 统一表意主区 + 扩展 A + 兼容表意区。
bool isCjk(int rune) =>
    (rune >= 0x3400 && rune <= 0x4DBF) || // 扩展 A
    (rune >= 0x4E00 && rune <= 0x9FFF) || // 统一表意主区
    (rune >= 0xF900 && rune <= 0xFAFF); // 兼容表意区

/// 假名：平假名 / 片假名 / 片假名音标扩展 / 半角片假名。
bool isKana(int rune) =>
    (rune >= 0x3040 && rune <= 0x309F) ||
    (rune >= 0x30A0 && rune <= 0x30FF) ||
    (rune >= 0x31F0 && rune <= 0x31FF) ||
    (rune >= 0xFF66 && rune <= 0xFF9D);

/// 谚文：音节 + 字母 + 兼容字母。
bool isHangul(int rune) =>
    (rune >= 0xAC00 && rune <= 0xD7AF) ||
    (rune >= 0x1100 && rune <= 0x11FF) ||
    (rune >= 0x3130 && rune <= 0x318F);

/// 需要**子串索引**的脚本（汉字 / 假名 / 谚文）——索引与查询两侧的 bigram 判据。
bool isIndexedScript(int rune) => isCjk(rune) || isKana(rune) || isHangul(rune);
