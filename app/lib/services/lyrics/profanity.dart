/// 歌词屏蔽词还原（对齐原项目 `utils/preset/profanity.ts`）。
///
/// 把歌词里被星号遮盖的脏话还原为原词（f**k → fuck 等），
/// 由「解锁脏话」设置控制是否启用。
library;

/// 还原单个文本中被星号遮盖的脏话（不区分大小写）。
String unmaskProfanity(String text) {
  if (text.isEmpty) return text;
  return text
      .replaceAll(RegExp(r'f\*{2}k', caseSensitive: false), 'fuck')
      .replaceAll(RegExp(r's\*{2}t', caseSensitive: false), 'shit')
      .replaceAll(RegExp(r'c\*{2}t', caseSensitive: false), 'cunt')
      .replaceAll(RegExp(r'c\*{2}k', caseSensitive: false), 'cock')
      .replaceAll(RegExp(r'co\*{2}', caseSensitive: false), 'cock')
      .replaceAll(RegExp(r's\*{2}ker', caseSensitive: false), 'sucker')
      .replaceAll(RegExp(r'\*{4}ing', caseSensitive: false), 'fucking')
      .replaceAll(RegExp(r'b\*{3}h', caseSensitive: false), 'bitch')
      .replaceAll(RegExp(r'd\*{2}k', caseSensitive: false), 'dick')
      .replaceAll(RegExp(r'd\*{2}n', caseSensitive: false), 'damn')
      .replaceAll(RegExp(r'\*{4}er', caseSensitive: false), 'fucker')
      .replaceAll(RegExp(r'as\*{2}le', caseSensitive: false), 'asshole')
      .replaceAll(RegExp(r'w\*{3}e', caseSensitive: false), 'whore')
      .replaceAll(RegExp(r'n\*{3}a', caseSensitive: false), 'nigga');
}
