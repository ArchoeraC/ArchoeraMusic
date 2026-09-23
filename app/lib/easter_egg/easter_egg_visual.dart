part of 'easter_egg.dart';

/// 颜色反转矩阵（RGB 取反，Alpha 保持不变）。
const ColorFilter _kEggInvertFilter = ColorFilter.matrix(<double>[
  -1, 0, 0, 0, 255, //
  0, -1, 0, 0, 255, //
  0, 0, -1, 0, 255, //
  0, 0, 0, 1, 0, //
]);

/// 把彩蛋全局视觉状态施加到整棵 UI：
///   - 内容位移：`ClipRect` + `Transform.translate`（#8 的 Wayland 回退）；
///   - 颜色反转：`ColorFiltered`（#10）；
///   - 左右镜像：`Transform` + `transformHitTests: false`（点击位置不变，#7）；
///   - 缩放：`Transform.scale`（#3）。
///
/// 组件级躲避（#6）不在这里，而是由 MouseDodge 挂在具体组件上。
/// 本组件由 `app.dart` 的 `MaterialApp.builder` 包在最外层（Navigator 之上）。
/// 同时承担调试开关 `ARCHOERA_EGG_AUTO=<id>`（启动即自动触发，免点按钮）。
class EasterEggVisualHost extends ConsumerStatefulWidget {
  const EasterEggVisualHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<EasterEggVisualHost> createState() =>
      _EasterEggVisualHostState();
}

class _EasterEggVisualHostState extends ConsumerState<EasterEggVisualHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoRun());
  }

  /// 调试：`ARCHOERA_EGG_AUTO=id1,id2` 时启动即自动触发（免点「千万别点」）。
  void _maybeAutoRun() {
    final raw = Platform.environment['ARCHOERA_EGG_AUTO'];
    if (raw == null || raw.trim().isEmpty) return;
    final ids = raw
        .split(',')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toSet();
    EasterEggEffect? effect;
    for (final e in kEasterEggEffects) {
      if (ids.contains(e.id)) {
        effect = e;
        break;
      }
    }
    if (effect == null) return;
    debugPrint('[easter-egg] AUTO 启动触发 ${effect.id}');
    runEasterEgg(
      EasterEggContext(context: context, effect: effect, ref: ref),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visual = ref.watch(easterEggVisualProvider);
    Widget result = widget.child;

    if (visual.contentShift != Offset.zero) {
      result = ClipRect(
        child: Transform.translate(offset: visual.contentShift, child: result),
      );
    }

    if (visual.invert) {
      result = ColorFiltered(colorFilter: _kEggInvertFilter, child: result);
    }

    if (visual.mirror) {
      final Matrix4 m = Matrix4.identity()..setEntry(0, 0, -1.0);
      result = Transform(
        alignment: Alignment.center,
        transformHitTests: false, // 命中原样（点击位置不变），仅视觉镜像
        transform: m,
        child: result,
      );
    }

    if (visual.zoom != 1.0) {
      result = Transform.scale(
        scale: visual.zoom,
        alignment: Alignment.topLeft,
        child: result,
      );
    }

    return result;
  }
}
