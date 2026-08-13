import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apis/runtime.dart';
import '../../l10n/l10n.dart';
import '../../services/downloader/download_controller.dart';
import '../../services/streaming/streaming_store.dart';
import '../../stores/providers.dart';
import '../../stores/vault_session_store.dart';

/// v2（口令模式）启动解锁门：凭据保险库为口令保护时，首帧显示全屏
/// 解锁页（输入会话口令 → 解锁会话 + 流媒体凭据 → 恢复登录态），
/// 解锁成功后才放行主界面。与 [VaultCrashGate] 并列：v2 每次会话
/// 都须解锁（口令仅内存持有，绝不持久化），跳过则登录态为空
/// （vault 持久化禁用，等同 v1 不可用降级语义）。
class VaultUnlockGate extends ConsumerStatefulWidget {
  const VaultUnlockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<VaultUnlockGate> createState() => _VaultUnlockGateState();
}

class _VaultUnlockGateState extends ConsumerState<VaultUnlockGate> {
  final TextEditingController _ctrl = TextEditingController();

  /// 会话 / 流媒体任一侧处于 v2 口令待解锁 → 需要解锁门。
  bool _needsUnlock = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // main 中 Store 已 initialize/preloadSecrets 完成，needsPassword 同步可读。
    // getRuntime 在 widget 测试未注入时可能抛错 → 容错按不需解锁处理。
    try {
      final s = getRuntime().sessionStore;
      _needsUnlock = (s is VaultSessionStore && s.needsPassword) ||
          StreamingStore.needsPassword;
    } catch (_) {
      _needsUnlock = false;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final password = _ctrl.text;
    if (password.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var ok = true;
      final s = getRuntime().sessionStore;
      if (s is VaultSessionStore && s.needsPassword) {
        ok = await s.unlockWithPassword(password) && ok;
      }
      if (StreamingStore.needsPassword) {
        ok = await StreamingStore.unlockWithPassword(password) && ok;
      }
      if (!ok) {
        setState(() => _error = context.l10n.vaultUnlockFailed);
        return;
      }
      // 解锁成功：重读登录态（vault 解锁前缓存为空）+ 重注下载引擎会话。
      // 网络异常不阻断解锁（登录态可能仍为空，用户可后续重登）。
      try {
        await ref.read(neteaseAuthProvider.notifier).init();
      } catch (e) {
        debugPrint('[vault] 解锁后登录态刷新失败：$e');
      }
      ref.read(downloadControllerProvider.notifier).syncSessions();
      if (mounted) setState(() => _needsUnlock = false);
    } finally {
      if (mounted && _needsUnlock) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_needsUnlock) return widget.child;
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.lock_outline, size: 56, color: scheme.primary),
                const SizedBox(height: 20),
                Text(
                  l10n.vaultUnlockTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Text(
                  l10n.vaultUnlockDesc,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _ctrl,
                  autofocus: true,
                  obscureText: _obscure,
                  enabled: !_busy,
                  onSubmitted: (_) => _unlock(),
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: l10n.vaultUnlockHint,
                    prefixIcon: const Icon(Icons.password_outlined),
                    isDense: true,
                    errorText: _error,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    suffixIcon: IconButton(
                      tooltip: l10n.settingsDeviceBindShowPassword,
                      iconSize: 18,
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _unlock,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_open_outlined, size: 18),
                  label: Text(l10n.vaultUnlockConfirm),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _needsUnlock = false),
                  child: Text(l10n.vaultUnlockSkip),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
