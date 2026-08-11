/// 天气数据服务（Open-Meteo + ip-api.com，均免费、无需 API 密钥）。
///
/// 数据链路（仅「天气组件开启」时才发起请求）：
///   - 手动城市：Open-Meteo geocoding（城市名 → 坐标），不涉及 IP；
///   - 自动定位：ip-api.com 按本机网络 IP 换取大致坐标（隐私：默认关闭，
///     见 [WeatherNotifier]）；当前天气：Open-Meteo forecast（lat/lon）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show IconData, Icons;

/// 当前天气快照。
class WeatherNow {
  const WeatherNow({
    required this.city,
    required this.tempC,
    required this.wmoCode,
  });

  /// 展示用城市名（定位/地理编码返回）。
  final String city;

  /// 气温（摄氏度）。
  final double tempC;

  /// WMO 天气码（Open-Meteo `current.weather_code`）。
  final int wmoCode;

  /// WMO 天气码 → Material 图标（微型组件仅用图标传达天气状况）。
  IconData get icon {
    final code = wmoCode;
    if (code == 0) return Icons.wb_sunny; // 晴
    if (code <= 2) return Icons.wb_cloudy; // 少云/多云
    if (code == 3) return Icons.cloud; // 阴
    if (code == 45 || code == 48) return Icons.blur_on; // 雾
    if (code >= 51 && code <= 57) return Icons.grain; // 毛毛雨
    if (code >= 61 && code <= 67) return Icons.water_drop; // 雨/冻雨
    if (code >= 71 && code <= 77) return Icons.ac_unit; // 雪
    if (code >= 80 && code <= 82) return Icons.umbrella; // 阵雨
    if (code >= 85 && code <= 86) return Icons.ac_unit; // 阵雪
    if (code >= 95) return Icons.flash_on; // 雷暴
    return Icons.cloud_outlined;
  }
}

/// 天气服务异常。
class WeatherException implements Exception {
  WeatherException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 拉取当前天气：按 [autoLocate] 走 IP 定位，否则按 [city] 手动地理编码。
///
/// [city] 为空且 [autoLocate] 为 false 时抛 [WeatherException]（调用方
/// 据此提示去设置填写城市/开启定位，不发起任何请求）。
Future<WeatherNow> fetchWeather({
  required bool autoLocate,
  String? city,
}) async {
  final geo = autoLocate
      ? await _locateByIp()
      : await _geocode(city?.trim() ?? '');
  final uri = Uri.parse('https://api.open-meteo.com/v1/forecast').replace(
    queryParameters: {
      'latitude': '${geo.lat}',
      'longitude': '${geo.lon}',
      'current': 'temperature_2m,weather_code',
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
  );
}

class _GeoPoint {
  const _GeoPoint(this.lat, this.lon, this.name);

  final double lat;
  final double lon;
  final String name;
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

/// IP 定位（ip-api.com 免费接口；仅「自动定位」开启时调用）。
Future<_GeoPoint> _locateByIp() async {
  final uri = Uri.parse(
    'https://ip-api.com/json/?fields=status,message,lat,lon,city,country',
  );
  final body = await _getJson(uri);
  if (body['status'] != 'success') {
    throw WeatherException(body['message']?.toString() ?? 'IP 定位失败');
  }
  final city = body['city']?.toString().trim() ?? '';
  final country = body['country']?.toString().trim() ?? '';
  final name = city.isNotEmpty ? city : (country.isNotEmpty ? country : '未知');
  return _GeoPoint(
    (body['lat'] as num).toDouble(),
    (body['lon'] as num).toDouble(),
    name,
  );
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
