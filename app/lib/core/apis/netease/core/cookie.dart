/// Cookie 解析与拼装——对齐 apis/netease/core/cookie.ts。
library;

/// 将 cookie 字符串转换为对象
Map<String, String> nmCookieToJson(String? cookie) {
  if (cookie == null || cookie.isEmpty) return {};
  final obj = <String, String>{};
  for (final item in cookie.split(';')) {
    final eq = item.indexOf('=');
    if (eq <= 0) continue;
    obj[item.substring(0, eq).trim()] = item.substring(eq + 1).trim();
  }
  return obj;
}

/// 将对象转换为 cookie 字符串（键值做 URI 编码，对齐 encodeURIComponent）
String nmCookieObjToString(Map<String, dynamic> cookie) => cookie.entries
    .map((e) =>
        '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent('${e.value}')}')
    .join('; ');
