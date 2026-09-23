part of 'easter_egg.dart';

/// 「千万别点」警告门。
///
/// 弹出警告正文，给出三个「确定」按钮；三个按钮行为相同——都按概率随机
/// 执行一个彩蛋（[pickEasterEgg]）。[effect] 仅供测试/定向注入（传了就必触发）。
///
/// [ref] 可选：彩蛋若需访问 Provider 可传入（`ConsumerState` 的 `ref`）。
Future<void> showEasterEggGate(
  BuildContext context, {
  WidgetRef? ref,
  EasterEggEffect? effect,
}) async {
  final l10n = context.l10n;

  final bool? confirmed = await SDialog.show<bool>(
    context,
    title: l10n.easterEggGateTitle,
    child: Text(
      l10n.easterEggGateBody,
      style: const TextStyle(fontSize: 13.5, height: 1.6),
    ),
    actions: <Widget>[
      // 三个按钮文案相同，行为也相同——都执行同一套概率抽彩蛋。
      for (int i = 0; i < 3; i++)
        SButton(
          label: l10n.commonConfirm,
          onPressed: () => Navigator.of(context).pop(true),
        ),
    ],
  );
  if (confirmed != true || !context.mounted) return;

  final EasterEggEffect? target = effect ?? pickEasterEgg();
  if (target == null) {
    debugPrint('[easter-egg] 本次未触发（概率未命中）');
    return;
  }
  await runEasterEgg(
    EasterEggContext(context: context, effect: target, ref: ref),
  );
}
