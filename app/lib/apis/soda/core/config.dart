// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水（soda / qishui）API 通用常量与公共参数。
///
/// **零第三方硬约束**（报告 §8.1）：出站只允许官方域名——`api.qishui.com`
/// （PC/Android 业务）、`beta-luna.douyin.com`（SEO seo_track）、
/// `vod-luna.douyin.com`（官方 VOD PlayInfo，由 SEO 响应的 `url_player_info` 指向）。
/// 签名服务 `api.music.qishui.vsaa.cn`、火山引擎 `api-vehicle.volcengine.com`
/// **不接入**（见报告 §7-P4）。
library;

/// 业务 API 根（PC `/luna/pc/*`、Android `/luna/*`）。
const sodaApiBase = 'https://api.qishui.com';

/// SEO 单曲接口（免登录、免签名；返回元数据 + KRC 歌词 + `url_player_info`）。
const sodaSeoBase = 'https://beta-luna.douyin.com/luna/h5/seo_track';

/// 图片 CDN（`url_cover` 归一）。
const sodaImageBase = 'https://p3-luna.douyinpic.com/img/';

/// 允许出站的官方域名白名单（测试断言；非白名单一律拒绝发起）。
const Set<String> sodaOfficialHosts = {
  'api.qishui.com',
  'beta-luna.douyin.com',
  'vod-luna.douyin.com',
  'p3-luna.douyinpic.com',
  'api5-lf.qishui.com',
};

/// Android 客户端 UA（搜索结果更全）。
const sodaAndroidUa =
    'com.luna.music/100198030 (Linux; U; Android 15; zh_CN_#Hans; '
    'ABR-AL80; Build/V417IR;tt-ok/3.12.13.19)';

/// PC 客户端 UA（专辑 / 歌单详情）。
const sodaPcUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';

/// PC App UA（`/luna/pc/*` 可读客户端）。
const sodaPcAppUa = 'LunaPC/3.3.0(359450208)';

/// Android 搜索公共参数（对齐 `music-lib/soda` `sodaAndroidSearchParams`）。
Map<String, String> sodaAndroidSearchParams() => const {
  'device_platform': 'android',
  'os': 'android',
  'ssmix': 'a',
  'cdid': '46556f98-1720-4248-83da-62b74b60b46a',
  'channel': 'xiaomi_8478_64',
  'aid': '386088',
  'app_name': 'luna',
  'version_code': '100198030',
  'version_name': '19.8.0',
  'manifest_version_code': '100198030',
  'update_version_code': '100198030',
  'resolution': '1080*1920',
  'dpi': '480',
  'device_type': 'ABR-AL80',
  'device_brand': 'HUAWEI',
  'language': 'zh',
  'os_api': '35',
  'os_version': '15',
  'ac': 'wifi',
  'device_model': 'ABR-AL80',
  'package': 'com.luna.music',
  'iid': '2204957404569386',
  'device_id': '2204957404565290',
};

/// PC App 公共参数（对齐 `music-lib/soda` `sodaPCAppParams`）。
///
/// `device_id`/`iid`/`fp` 取当前毫秒（访客稳定；无需真实设备号）。
Map<String, String> sodaPcAppParams() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'aid': '386088',
    'app_name': 'luna_pc',
    'region': 'cn',
    'geo_region': 'cn',
    'os_region': 'cn',
    'sim_region': '',
    'device_id': '$now',
    'cdid': '',
    'iid': '${now + 1}',
    'version_name': '3.3.0',
    'version_code': '30030000',
    'channel': 'official',
    'build_mode': 'master',
    'network_carrier': '',
    'ac': 'wifi',
    'tz_name': 'Asia/Shanghai',
    'resolution': '',
    'device_platform': 'windows',
    'device_type': 'Windows',
    'os_version': 'Windows 11',
    'fp': '$now',
  };
}
