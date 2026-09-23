part of 'easter_egg.dart';

/// 全局彩蛋注册表（「千万别点」随机池，共 10 个）。
///
/// `weight` 为抽中权重（相对比例）：致命的最稀有、无害的更常见。
/// 当前分配：致命 #1/#5 = 1；烦人 #2/#9 = 2；其余 = 3（合计 24）。
/// 除 #2 minimize（限时恢复）外，其余彩蛋均为**永久生效、不还原**。
/// 新增彩蛋：实现 `Future<void> Function(EasterEggContext)` 后在此追加一条。
const List<EasterEggEffect> kEasterEggEffects = <EasterEggEffect>[
  EasterEggEffect(id: 'not_responding', run: _notResponding, weight: 1), // #1
  EasterEggEffect(id: 'minimize_trap', run: _minimizeTrap, weight: 2), // #2
  EasterEggEffect(id: 'zoom_800', run: _zoom800, weight: 3), // #3
  EasterEggEffect(id: 'theme_strobe', run: _themeStrobe, weight: 3), // #4
  EasterEggEffect(id: 'quit_now', run: _quitNow, weight: 1), // #5
  EasterEggEffect(id: 'flee_mouse', run: _fleeMouse, weight: 3), // #6
  EasterEggEffect(id: 'mirror', run: _mirror, weight: 3), // #7
  EasterEggEffect(id: 'desktop_scroll', run: _desktopScroll, weight: 3), // #8
  EasterEggEffect(id: 'pause_lock', run: _pauseLock, weight: 2), // #9
  EasterEggEffect(id: 'invert_colors', run: _invertColors, weight: 3), // #10
];

/// 触发概率（「随机一种但概率出现」）：约 50% 触发，否则什么都不发生。
const double kEasterEggChance = 0.5;

/// 安全模式：环境变量 `ARCHOERA_EGG_SAFE=1` 时跳过**不可逆**彩蛋
/// （#1 永久卡死 / #5 退出），便于开发调试；正常使用不设该变量。
final bool kEasterEggSafeMode =
    Platform.environment['ARCHOERA_EGG_SAFE'] == '1';

final math.Random _easterEggRng = math.Random();

/// 调试用随机池：`ARCHOERA_EGG_FORCE=id1,id2` 时只从这些 id 里抽（且必触发）。
List<EasterEggEffect> _forcedPool() {
  final raw = Platform.environment['ARCHOERA_EGG_FORCE'];
  if (raw == null || raw.trim().isEmpty) return const <EasterEggEffect>[];
  final ids = raw
      .split(',')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toSet();
  return kEasterEggEffects
      .where((EasterEggEffect e) => ids.contains(e.id))
      .toList(growable: false);
}

/// 有效触发概率：默认 [kEasterEggChance]，`ARCHOERA_EGG_CHANCE`（0-1）可覆盖。
double _effectiveChance() {
  final raw = Platform.environment['ARCHOERA_EGG_CHANCE'];
  final v = raw == null ? null : double.tryParse(raw);
  return v == null ? kEasterEggChance : v.clamp(0.0, 1.0);
}

/// 先按概率决定是否触发，命中后按各彩蛋 [EasterEggEffect.weight] 加权随机抽一个；
/// 未命中返回 null（本次无事发生）。
///
/// [chance] 显式指定时优先（默认走 [kEasterEggChance]，可被 `ARCHOERA_EGG_CHANCE`
/// 覆盖）；[random] 仅供测试注入（确定性）。`ARCHOERA_EGG_FORCE` 非空时只抽这些
/// 且必定触发——用于逐个验证某个彩蛋。
EasterEggEffect? pickEasterEgg({double? chance, math.Random? random}) {
  final rng = random ?? _easterEggRng;
  final forced = _forcedPool();
  final pool = forced.isEmpty ? kEasterEggEffects : forced;
  final p = forced.isNotEmpty ? 1.0 : (chance ?? _effectiveChance());
  if (rng.nextDouble() >= p) return null;

  final total = pool.fold<int>(0, (sum, e) => sum + e.weight);
  var roll = rng.nextInt(total);
  for (final effect in pool) {
    if (roll < effect.weight) return effect;
    roll -= effect.weight;
  }
  return pool.last; // 理论不可达（weight 均为正）
}

/// 执行单个彩蛋：统一兜底异常（彩蛋不应把应用弄崩）。
Future<void> runEasterEgg(EasterEggContext ctx) async {
  debugPrint('[easter-egg] 执行 ${ctx.effect.id}');
  try {
    await ctx.effect.run(ctx);
  } catch (error, stack) {
    debugPrint('[easter-egg] 效果 ${ctx.effect.id} 执行失败：$error\n$stack');
  }
}
