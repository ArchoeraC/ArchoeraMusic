/// 天气数据服务（Open-Meteo + ipwho.is + BigDataCloud，均免费、无需密钥）。
///
/// 数据链路（仅「天气组件开启」时才发起请求）：
///   - 手动城市：Open-Meteo geocoding（城市名 → 坐标），不涉及 IP；
///   - 自动定位：定位来源可选——
///       `ip`：ipwho.is 按本机网络 IP 换取大致坐标（隐私：默认关闭）；
///       `system`：优先系统定位（Windows 定位 / Linux GeoClue，见
///       [WeatherNotifier]），失败/不可用自动回退 IP；坐标 → 城市名用
///       BigDataCloud reverse-geocode（best-effort，失败仅影响展示名）。
///     当前天气：Open-Meteo forecast（lat/lon）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show Color, Colors, IconData, Icons;
import 'package:geolocator/geolocator.dart';

/// 当前天气快照。
class WeatherNow {
  const WeatherNow({
    required this.city,
    required this.tempC,
    required this.wmoCode,
    this.isDay = true,
  });

  /// 展示用城市名（定位/地理编码返回）。
  final String city;

  /// 气温（摄氏度）。
  final double tempC;

  /// WMO 天气码（Open-Meteo `current.weather_code`）。
  final int wmoCode;

  /// 是否白天（Open-Meteo `current.is_day`；晴/少云图标按昼夜区分形态）。
  final bool isDay;

  /// WMO 天气码 → 图标。对齐 noctalia `glyphForCode` 的昼夜分类：
  /// 晴（0）与少云（1-2）分昼夜，阴/雾/雨/雪/雷暴为固定形态。
  IconData get icon {
    final code = wmoCode;
    if (code == 0) return isDay ? Icons.wb_sunny : Icons.nights_stay;
    if (code == 1 || code == 2) {
      return isDay ? Icons.wb_cloudy : Icons.cloud_queue;
    }
    if (code == 3) return Icons.cloud;
    if (code == 45 || code == 48) return Icons.foggy;
    if (code >= 51 && code <= 57) return Icons.grain;
    if (code >= 61 && code <= 67) return Icons.water_drop;
    if (code >= 71 && code <= 77) return Icons.ac_unit;
    if (code >= 80 && code <= 82) return Icons.water_drop;
    if (code >= 85 && code <= 86) return Icons.ac_unit;
    if (code >= 95) return Icons.thunderstorm;
    return Icons.cloud_outlined;
  }

  /// 语义色（win10 天气风格：太阳黄 / 云灰 / 雨蓝 / 雪青 / 雷暴紫）。
  Color get color {
    final code = wmoCode;
    if (code == 0) return isDay ? Colors.amber : Colors.indigo.shade300;
    if (code == 1 || code == 2) return Colors.blueGrey;
    if (code == 3 || code == 45 || code == 48) {
      return Colors.blueGrey.shade400;
    }
    if (code >= 51 && code <= 67) return Colors.lightBlue;
    if (code >= 71 && code <= 77) return Colors.lightBlue.shade200;
    if (code >= 80 && code <= 82) return Colors.blue;
    if (code >= 85 && code <= 86) return Colors.lightBlue.shade200;
    if (code >= 95) return Colors.deepPurpleAccent;
    return Colors.blueGrey;
  }
}

/// 天气服务异常。
class WeatherException implements Exception {
  WeatherException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 拉取当前天气：按 [autoLocate] 走自动定位（来源 [locateSource]），
/// 否则按 [city] 手动地理编码。
///
/// [city] 为空且 [autoLocate] 为 false 时抛 [WeatherException]（调用方
/// 据此提示去设置填写城市/开启定位，不发起任何请求）。[locateSource] 为
/// `system` 时优先系统定位，失败/不可用自动回退 IP 定位。
Future<WeatherNow> fetchWeather({
  required bool autoLocate,
  String? city,
  String locateSource = 'ip',
}) async {
  final geo = autoLocate
      ? await _locateAuto(locateSource: locateSource)
      : await _geocode(city?.trim() ?? '');
  final uri = Uri.parse('https://api.open-meteo.com/v1/forecast').replace(
    queryParameters: {
      'latitude': '${geo.lat}',
      'longitude': '${geo.lon}',
      'current': 'temperature_2m,weather_code,is_day',
      'timezone': 'auto',
    },
  );
  final body = await _getJson(uri);
  final current = body['current'];
  if (current is! Map<String, dynamic>) {
    throw WeatherException('天气数据为空');
  }
  return WeatherNow(
    city: geo.name,
    tempC: (current['temperature_2m'] as num?)?.toDouble() ?? 0,
    wmoCode: (current['weather_code'] as num?)?.toInt() ?? 0,
    isDay: (current['is_day'] as num?)?.toInt() != 0,
  );
}

class _GeoPoint {
  const _GeoPoint(this.lat, this.lon, this.name);

  final double lat;
  final double lon;
  final String name;
}

/// 自动定位：`system` 优先系统定位，失败/不可用回退 IP；`ip` 直接 IP。
Future<_GeoPoint> _locateAuto({required String locateSource}) async {
  if (locateSource == 'system') {
    try {
      return await _locateBySystem();
    } catch (_) {
      // 系统定位不可用（无 GeoClue/定位服务/权限被拒等）→ 回退 IP
    }
  }
  return _locateByIp();
}

/// 城市名 → 坐标（Open-Meteo geocoding；不发送 IP）。
Future<_GeoPoint> _geocode(String city) async {
  final name = city.trim();
  if (name.isEmpty) {
    throw WeatherException('no_location');
  }
  final uri = Uri.parse(
    'https://geocoding-api.open-meteo.com/v1/search',
  ).replace(queryParameters: {'name': name, 'count': '1', 'format': 'json'});
  final body = await _getJson(uri);
  final results = body['results'];
  if (results is! List || results.isEmpty) {
    throw WeatherException('城市未找到: $name');
  }
  final first = results.first;
  if (first is! Map<String, dynamic>) {
    throw WeatherException('城市未找到: $name');
  }
  return _GeoPoint(
    (first['latitude'] as num).toDouble(),
    (first['longitude'] as num).toDouble(),
    first['name']?.toString().trim().isNotEmpty == true
        ? first['name'].toString().trim()
        : name,
  );
}

/// IP 定位（ipwho.is 免费接口；仅「自动定位」开启时调用）。
///
/// 历史：原 ip-api.com 免费层已停止 HTTPS 支持（403 "SSL unavailable for
/// this endpoint"），自动定位必然失败 → 换用 ipwho.is（免费、HTTPS、无 key，
/// 返回 latitude/longitude/city/country）。
Future<_GeoPoint> _locateByIp() async {
  final uri = Uri.parse('https://ipwho.is/');
  final body = await _getJson(uri);
  if (body['success'] != true) {
    throw WeatherException(body['message']?.toString() ?? 'IP 定位失败');
  }
  final lat = body['latitude'];
  final lon = body['longitude'];
  if (lat is! num || lon is! num) {
    throw WeatherException('IP 定位失败');
  }
  final city = body['city']?.toString().trim() ?? '';
  final country = body['country']?.toString().trim() ?? '';
  final name = city.isNotEmpty ? city : (country.isNotEmpty ? country : '未知');
  return _GeoPoint(lat.toDouble(), lon.toDouble(), name);
}

/// 系统定位（Geolocator：Windows 定位 API / Linux GeoClue2）。
///
/// 仅天气需要的城市级精度，用 [LocationAccuracy.low]（更省电、权限更易
/// 通过）；8s 超时防止系统定位服务长时间无响应。坐标 → 城市名走
/// BigDataCloud reverse-geocode（best-effort，失败仅回退展示名，不丢坐标）。
/// 系统定位不可用（无服务/权限被拒/测试环境无插件）时抛异常，由
/// [_locateAuto] 回退 IP。
Future<_GeoPoint> _locateBySystem() async {
  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.low,
      timeLimit: Duration(seconds: 8),
    ),
  );
  final name = await _reverseName(position.latitude, position.longitude);
  return _GeoPoint(position.latitude, position.longitude, name);
}

/// 坐标 → 城市名（BigDataCloud reverse-geocode-client，免费无 key）。
///
/// 名称优先级：city → principalSubdivision（省/州）→ countryName；
/// 全部缺失或请求失败返回兜底「系统定位」（仅影响展示，天气仍按坐标）。
Future<String> _reverseName(double lat, double lon) async {
  const fallback = '系统定位';
  final uri = Uri.parse(
    'https://api.bigdatacloud.net/data/reverse-geocode-client',
  ).replace(
    queryParameters: {
      'latitude': '$lat',
      'longitude': '$lon',
      'localityLanguage': 'zh',
    },
  );
  try {
    final body = await _getJson(uri);
    final city = body['city']?.toString().trim() ?? '';
    if (city.isNotEmpty) return city;
    final region = body['principalSubdivision']?.toString().trim() ?? '';
    if (region.isNotEmpty) return region;
    final country = body['countryName']?.toString().trim() ?? '';
    if (country.isNotEmpty) return country;
  } catch (_) {}
  return fallback;
}

/// 一次 JSON GET（对齐 kgGet 的 HttpClient 直连风格）。
Future<Map<String, dynamic>> _getJson(Uri uri) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 8));
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final res = await req.close().timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      throw WeatherException('HTTP ${res.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is! Map<String, dynamic>) {
      throw WeatherException('响应格式错误');
    }
    return decoded;
  } finally {
    client.close(force: true);
  }
}
