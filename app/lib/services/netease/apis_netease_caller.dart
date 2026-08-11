/// 网易云直连调用器（新 apis 包完整移植版）
///
/// 对齐 apis/netease/index.ts 的 callNetease 语义：按 name 路由到对应模块，
/// 返回网易云原始响应体（`{code, result...}` / `{code, data...}`）。
/// 覆盖全部 73 个模块（旧 NeteaseDirectCaller 仅 cloudsearch/song_url），
/// 且 nmCallNetease 自带 LRU 响应缓存。
library;

import '../../apis/netease/api.dart';
import 'netease_api.dart';

class ApisNeteaseCaller implements NeteaseCaller {
  @override
  Future<Map<String, dynamic>?> call(String name, Map<String, dynamic> params) async {
    try {
      final res = await nmCallNetease(name, params);
      return res.body;
    } catch (_) {
      // 非 200 / 网络错误统一返回 null，由 NeteaseApi 解析层兜底
      return null;
    }
  }
}
