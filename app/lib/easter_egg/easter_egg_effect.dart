part of 'easter_egg.dart';

/// 彩蛋执行上下文：把执行期可用的 UI 能力与 Riverpod 容器交给效果实现，
/// 使彩蛋无需自己去找 Navigator / ProviderScope。
class EasterEggContext {
  const EasterEggContext({
    required this.context,
    required this.effect,
    this.ref,
  });

  /// 触发彩蛋时的宿主 [BuildContext]（弹窗 / toast / navigator 用）。
  final BuildContext context;

  /// 正在执行的彩蛋（便于日志 / 自省）。
  final EasterEggEffect effect;

  /// Riverpod 容器；纯 UI 彩蛋或测试场景可为 null。
  final WidgetRef? ref;
}

/// 一个具名彩蛋效果。
///
/// [id] 用于日志与调试；[run] 是效果本体，允许 await（动画 / 延时 / 弹窗皆可），
/// 抛出的异常由 [runEasterEgg] 统一兜底，不会弄崩应用。
/// [weight] 是抽中权重（相对比例，见 [pickEasterEgg]）；必须为正整数。
class EasterEggEffect {
  const EasterEggEffect({
    required this.id,
    required this.run,
    this.weight = 1,
  });

  /// 稳定且唯一的标识（仅用于日志 / 自省，不参与显示）。
  final String id;

  /// 执行入口。
  final Future<void> Function(EasterEggContext ctx) run;

  /// 抽中权重（相对比例）；越大越容易被抽中。
  final int weight;
}
