import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/security/vault_process.dart';
import '../../stores/data_dir.dart';

/// 凭据模块崩溃警告门（credential-vault-plan §3.7 fail-closed）：
/// 启动时若上次会话异常退出（`vault.marker` = crash），首帧弹显著警告——
/// 本地凭据可能已暴露，提供「销毁并重建」一键跳转重置。
///
/// 消费即清除（[VaultProcess.consumeCrashMarker]），避免每次启动重复提示；
/// 正常退出（ok）/主动报错（fail）不弹。
class VaultCrashGate extends StatefulWidget {
  const VaultCrashGate({super.key, required this.child});

  final Widget child;

  @override
  State<VaultCrashGate> createState() => _VaultCrashGateState();
}

class _VaultCrashGateState extends State<VaultCrashGate> {
  bool _consumed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeWarn());
  }

  Future<void> _maybeWarn() async {
    if (_consumed || !mounted) return;
    _consumed = true;
    final crashed = VaultProcess.consumeCrashMarker(resolveDataDir());
    if (!crashed || !mounted) return;
    final l10n = context.l10n;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: Text(l10n.vaultCrashTitle),
        content: Text(l10n.vaultCrashDesc),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.vaultCrashDismiss),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _wipeAndRebuild();
            },
            child: Text(l10n.vaultCrashReset),
          ),
        ],
      ),
    );
  }

  /// 销毁 vault（凭据不可恢复）——用户重新登录即重建。
  Future<void> _wipeAndRebuild() async {
    if (!mounted) return;
    try {
      VaultProcess.destroy(resolveDataDir());
    } catch (e) {
      debugPrint('[vault] 销毁失败：$e');
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.toastSecurityAllDestroyed)),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
