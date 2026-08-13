import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/security/vault_process.dart';

/// vault 版本异常门（fail-closed）：握手时发现 vault 二进制非官方生产构建
/// （TEST 标记/缺失 marker）→ 副本已删除、解密已拒绝——本门显示全屏警告，
/// **仅允许用户退出**（不提供销毁/重试等任何继续操作，杜绝再次参与解密）。
///
/// 监听 [VaultProcess.versionFatal]：置位即全屏拦截，正常态直通 [child]。
class VaultVersionGate extends StatefulWidget {
  const VaultVersionGate({super.key, required this.child});

  final Widget child;

  @override
  State<VaultVersionGate> createState() => _VaultVersionGateState();
}

class _VaultVersionGateState extends State<VaultVersionGate> {
  VaultFatalReason? _reason;

  @override
  void initState() {
    super.initState();
    _reason = VaultProcess.versionFatal.value;
    VaultProcess.versionFatal.addListener(_onFatal);
  }

  @override
  void dispose() {
    VaultProcess.versionFatal.removeListener(_onFatal);
    super.dispose();
  }

  void _onFatal() {
    if (mounted) setState(() => _reason = VaultProcess.versionFatal.value);
  }

  @override
  Widget build(BuildContext context) {
    final reason = _reason;
    if (reason == null) return widget.child;
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.gpp_bad_outlined,
                    size: 64, color: scheme.error),
                const SizedBox(height: 20),
                Text(
                  l10n.vaultVersionTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.vaultVersionDesc,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  switch (reason) {
                    VaultFatalReason.binaryReplaced =>
                      l10n.vaultVersionReasonReplaced,
                    VaultFatalReason.markerMissing =>
                      l10n.vaultVersionReasonMarkerMissing,
                    VaultFatalReason.markerMismatch =>
                      l10n.vaultVersionReasonMarkerMismatch,
                  },
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: scheme.error,
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => exit(0),
                  icon: const Icon(Icons.exit_to_app_outlined, size: 18),
                  label: Text(l10n.vaultVersionExit),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
