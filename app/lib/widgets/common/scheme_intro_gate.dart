import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../stores/app_prefs.dart';

/// 首次启动「凭据加密方案」介绍门（一次性）：
/// 提醒默认启用 LEGACY（推荐、稳定），Vault（实验性）可在
/// 设置 → 凭据加密方案 中切换；消费 [AppPrefs.schemeDialogShown] 标记，
/// 已展示即不再弹（避免每次启动打扰）。
class SchemeIntroGate extends ConsumerStatefulWidget {
  const SchemeIntroGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SchemeIntroGate> createState() => _SchemeIntroGateState();
}

class _SchemeIntroGateState extends ConsumerState<SchemeIntroGate> {
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  Future<void> _maybeShow() async {
    if (_done || !mounted) return;
    _done = true;
    final shown = ref.read(appPrefsProvider).schemeDialogShown;
    if (shown || !mounted) return;
    final l10n = context.l10n;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.security_outlined),
        title: Text(l10n.settingsSchemeIntroTitle),
        content: Text(
          l10n.settingsSchemeIntroDesc,
          style: const TextStyle(height: 1.45),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.settingsSchemeIntroGotIt),
          ),
        ],
      ),
    );
    if (!mounted) return;
    // 无论用户选择与否都消费标记：后续切换入口在设置页。
    ref.read(appPrefsProvider.notifier).setSchemeDialogShown(true);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
