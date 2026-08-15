import 'dart:async';

import 'package:flutter/foundation.dart';

import 'weather_api.dart';

/// 天气错误哨兵：未配置任何位置（自动定位关 + 城市为空）时使用，
/// UI 据此提示用户去设置（而非显示网络错误）。
const weatherNoLocationError = 'no_location';

/// 天气状态控制器（顶栏微型天气组件的数据源）。
///
/// 隐私设计：默认关闭（见 `appearance.weatherEnabled`），关闭期间不持有
/// 定时器、不发起任何定位/天气请求；[refresh] 仅在 UI 明确传入位置配置
/// （IP 自动定位或手动城市）时才访问第三方服务。
class WeatherNotifier extends ChangeNotifier {
  /// 最近一次成功数据（null = 尚无数据）。
  WeatherNow? now;

  /// 是否正在拉取。
  bool loading = false;

  /// 错误信息（[weatherNoLocationError] = 未配置位置；其余为网络/解析错误）。
  String? error;

  /// 拉取当前天气。由 UI 传入位置配置（来自偏好设置）。
  ///
  /// [locateSource]：`ip` 按出口 IP；`system` 优先系统定位（失败回退 IP）。
  Future<void> refresh({
    required bool autoLocate,
    String? city,
    String locateSource = 'ip',
  }) async {
    // 未配置位置：不发请求，提示去设置（默认定位关闭的兜底）
    if (!autoLocate && (city == null || city.trim().isEmpty)) {
      now = null;
      error = weatherNoLocationError;
      loading = false;
      notifyListeners();
      return;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      now = await fetchWeather(
        autoLocate: autoLocate,
        city: city,
        locateSource: locateSource,
      );
    } catch (e) {
      now = null;
      error = '$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}
