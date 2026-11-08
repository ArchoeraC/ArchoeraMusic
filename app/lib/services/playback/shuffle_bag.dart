// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

/// 随机播放「待播袋」：只保存尚未播放的曲目键，不改变播放队列顺序。
///
/// 开启随机后，队列面板仍按用户添加/排序后的原顺序展示；续播时从本袋中
/// 随机取下一首，取完一轮后由调用方重新装填，从而既保持队列位置不变，
/// 又不会在同一轮里重复播放同一首。
class ShuffleBag {
  ShuffleBag([math.Random? random]) : _random = random ?? math.Random();

  final math.Random _random;
  final List<String> _keys = <String>[];

  bool get isEmpty => _keys.isEmpty;

  int get length => _keys.length;

  /// 用 [keys] 重置待播袋（通常排除当前正在播放的曲目）。
  void reset(Iterable<String> keys) {
    _keys
      ..clear()
      ..addAll(keys);
  }

  void clear() => _keys.clear();

  /// 添加待播键（已存在则不重复添加）。
  void add(String key) {
    if (!_keys.contains(key)) _keys.add(key);
  }

  bool remove(String key) => _keys.remove(key);

  /// 只保留满足 [test] 的键（清理已从队列删除的曲目）。
  void retainWhere(bool Function(String key) test) => _keys.retainWhere(test);

  /// 随机取出一个待播键；空袋返回 null。
  String? take() {
    if (_keys.isEmpty) return null;
    return _keys.removeAt(_random.nextInt(_keys.length));
  }
}
