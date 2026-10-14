// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 中文（CJK）查询的**编辑距离 ≤ 1 变体生成**（**纯函数，无 FFI / 无 IO，可单测**）。
///
/// 设计文档 `docs/local-search-index-plan.md` §4.6「容错」：拼音分支天然覆盖
/// **同音错字**（错字与正字拼音相同 → 命中）；**非同音错字 / 漏字 / 换位**需要
/// 在查询侧做字符级扩展。本层只做**变体生成**，实际分词 / 编译交给原生分析器
/// （同构，见 `search_index.dart` 的第三趟），故这里是**唯一**的 Dart 侧字符处理，
/// 不重实现分词。
///
/// 语义（与拉丁 [compileFuzzy] 的编辑距离 ≤ 1 规则对齐）：
///   - **删除**：去掉任一字符（对应用户**多打**一个字）；
///   - **相邻换位**：交换相邻两字符（对应用户**打反**两个字）；
///   - **不含插入**（把漏打的字补回需要词表，本期不做，见报告覆盖边界）；
///   - 变体**不含原串**（原串已由精确第一趟覆盖），去重保序；
///   - 变体数随长度线性增长（≤ 2L−3），受 [defaultMaxCjkVariants] 约束；
///   - 超长查询（> [maxCjkQueryLength]）直接放弃（避免病态输入放大开销）。
library;

import 'script_ranges.dart';

/// 汉字（表意）码元——**拼音高亮专用**（假名 / 谚文没有拼音读音）。
///
/// 均为 BMP 码元，1 字符 ↔ 1 UTF-16 码元，故按码元处理安全。
bool isCjkCodeUnit(int unit) => isCjk(unit);

/// 需要**子串索引**的脚本码元（汉字 / 假名 / 谚文，与原生 `ScriptRanges` 一致）：
/// 这些脚本的漏字 / 相邻换位容错才有意义（假名同样是 bigram 索引，见设计文档 §4.1）。
bool isIndexedScriptCodeUnit(int unit) => isIndexedScript(unit);

/// 查询是否含任意子串脚本字符（决定是否启用第三趟容错）。
bool queryHasCjk(String query) {
  for (var i = 0; i < query.length; i++) {
    if (isIndexedScriptCodeUnit(query.codeUnitAt(i))) return true;
  }
  return false;
}

/// 取查询中的 **CJK 子序列**（去非 CJK，保序；不做 NFKC / 繁简——交给分析器）。
///
/// 例：`周杰伦` → `周杰伦`；`周 杰伦!` → `周杰伦`；`abc` → `''`。
String cjkSubsequence(String query) {
  final buf = StringBuffer();
  for (var i = 0; i < query.length; i++) {
    final unit = query.codeUnitAt(i);
    if (isIndexedScriptCodeUnit(unit)) buf.writeCharCode(unit);
  }
  return buf.toString();
}

/// 单次中文容错的**变体总数**默认上限（按长度自适应：短查询远低于此，长查询截断）。
const int defaultMaxCjkVariants = 200;

/// CJK 子序列的长度硬上限：超长（粘贴整段文本）放弃容错，避免 O(L²) 膨胀。
const int maxCjkQueryLength = 64;

/// 生成 [query] 的 CJK 编辑距离 ≤ 1 变体（删除任一字符 / 相邻换位）。
///
/// 返回**不含原 CJK 子序列**的去重列表（保序：先按位置删除，再按位置换位），
/// 超 [maxVariants] 截断；子序列长度 < 2 或 > [maxCjkQueryLength] 返回空。
/// 仅做字符处理，**不**分词——调用方须用原生分析器（同构）分析每个变体。
List<String> cjkVariants(
  String query, {
  int maxVariants = defaultMaxCjkVariants,
}) {
  final sequence = cjkSubsequence(query);
  // BMP 内 CJK，按码元切分安全。
  if (sequence.length < 2 || sequence.length > maxCjkQueryLength) {
    return const [];
  }

  final out = <String>[];
  final seen = <String>{sequence};

  void add(String candidate) {
    if (candidate.isEmpty) return;
    if (seen.add(candidate)) out.add(candidate);
  }

  // 删除：去掉任一字符（用户多打一字）。
  for (var i = 0; i < sequence.length; i++) {
    add(sequence.substring(0, i) + sequence.substring(i + 1));
  }
  // 相邻换位（跳过相同字符对：换位无意义且与原串相同）。
  for (var i = 0; i + 1 < sequence.length; i++) {
    if (sequence.codeUnitAt(i) == sequence.codeUnitAt(i + 1)) continue;
    add(sequence.substring(0, i) +
        sequence.substring(i + 1, i + 2) +
        sequence.substring(i, i + 1) +
        sequence.substring(i + 2));
  }

  if (out.length > maxVariants) return out.sublist(0, maxVariants);
  return out;
}
