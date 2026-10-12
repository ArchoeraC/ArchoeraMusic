// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apis/runtime.dart';
import '../../l10n/l10n.dart';
import '../../services/downloader/download_controller.dart';
import '../../services/log/log.dart';
import '../../services/streaming/streaming_store.dart';
import '../../stores/providers.dart';
import '../../stores/vault_session_store.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'vault_unlock_gate/vault_unlock_gate_view.dart';

/// 凭据解锁门：保险库为口令保护（m1/m2a）时，首帧显示全屏解锁页
/// （输入口令 → 解锁会话 + 流媒体凭据 → 恢复登录态），解锁成功后才放行。
/// 与 [VaultCrashGate] 并列：
///   - m1/m2a：口令解锁；m2a 另提供「使用恢复码解锁」兜底入口
///     （device.key 缺失/换机时经恢复槽解锁）；
///   - m2b 与 crypto/file：免密，无需解锁（直接放行）。
/// 每次会话都须解锁（口令仅内存持有，绝不持久化），跳过则登录态为空
/// （vault 持久化禁用，等同不可用降级语义）。
class VaultUnlockGate extends ConsumerStatefulWidget {
  const VaultUnlockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<VaultUnlockGate> createState() => _VaultUnlockGateState();
}

class _VaultUnlockGateState extends ConsumerState<VaultUnlockGate> {
  final TextEditingController _ctrl = TextEditingController();

  /// 会话 / 流媒体任一侧处于 m1/m2a 待解锁 → 需要解锁门。
  bool _needsUnlock = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  /// vault 模式（`m1`/`m2a`/`m2b`/`crypto`；未探测为 null）。
  String? _mode;

  /// 设备密钥（device.key）缺失 → 必须用恢复码（m2a 恢复槽）解锁。
  bool _needsRecovery = false;

  /// 用户当前选择「使用恢复码解锁」入口（仅 m2a 可用）。
  bool _useRecovery = false;

  bool get _isM2a => _mode == 'm2a';

  @override
  void initState() {
    super.initState();
    // main 中 Store 已 initialize/preloadSecrets 完成，needsPassword 同步可读。
    // getRuntime 在 widget 测试未注入时可能抛错 → 容错按不需解锁处理。
    try {
      final s = getRuntime().sessionStore;
      final sessionStore = s is VaultSessionStore ? s : null;
      _needsUnlock =
          (sessionStore?.needsPassword ?? false) || StreamingStore.needsPassword;
      _mode = sessionStore?.mode ?? StreamingStore.mode;
      _needsRecovery = (sessionStore?.needsRecovery ?? false) ||
          StreamingStore.needsRecovery;
      // 设备密钥缺失：直接进入恢复码通道（口令路径必然 NEED_RECOVERY）。
      if (_needsRecovery) _useRecovery = true;
    } catch (_) {
      _needsUnlock = false;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool _storeNeedsRecovery() {
    try {
      final s = getRuntime().sessionStore;
      return (s is VaultSessionStore && s.needsRecovery) ||
          StreamingStore.needsRecovery;
    } catch (_) {
      return false;
    }
  }

  Future<void> _unlock() async {
    final value = _ctrl.text;
    if (value.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var ok = true;
      final s = getRuntime().sessionStore;
      if (_useRecovery) {
        // m2a 恢复槽：恢复码经 store 透传 VaultProcess.get(recoveryCode:)。
        if (s is VaultSessionStore) {
          ok = await s.recover(value) && ok;
        }
        ok = await StreamingStore.recover(value) && ok;
      } else {
        if (s is VaultSessionStore && s.needsPassword) {
          ok = await s.unlockWithPassword(value) && ok;
        }
        if (StreamingStore.needsPassword) {
          ok = await StreamingStore.unlockWithPassword(value) && ok;
        }
      }
      if (!ok) {
        // 设备密钥缺失（口令路径 NEED_RECOVERY）→ 自动切到恢复码通道并说明，
        // 不静默失败、不误导为「口令错误」。
        final needsRecovery = _storeNeedsRecovery();
        setState(() {
          _needsRecovery = needsRecovery;
          if (needsRecovery && _isM2a) _useRecovery = true;
          _error = needsRecovery
              ? context.l10n.vaultUnlockNeedRecovery
              : (_useRecovery
                  ? context.l10n.vaultUnlockRecoveryFailed
                  : context.l10n.vaultUnlockFailed);
        });
        return;
      }
      // 解锁成功：重读登录态（vault 解锁前缓存为空）+ 重注下载引擎会话。
      // 网络异常不阻断解锁（登录态可能仍为空，用户可后续重登）。
      try {
        await ref.read(neteaseAuthProvider.notifier).init();
      } catch (e) {
        Log.e('vault', '解锁后登录态刷新失败：$e');
      }
      ref.read(downloadControllerProvider.notifier).syncSessions();
      if (mounted) setState(() => _needsUnlock = false);
    } finally {
      if (mounted && _needsUnlock) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _buildVaultUnlockGate(context);

  void _toggleObscure() {
    setState(() => _obscure = !_obscure);
  }

  void _skipUnlock() {
    setState(() => _needsUnlock = false);
  }

  void _toggleRecovery() {
    setState(() {
      _useRecovery = !_useRecovery;
      _error = null;
      _ctrl.clear();
    });
  }
}
