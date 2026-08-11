/// 存储分类下的「安全销毁」危险区（敏感数据不可逆擦除）。
///
/// 对齐需求：必要情况下允许用户直接销毁敏感数据库 ——
/// 主动失效 token（网易云 /api/logout）+ 随机数据覆盖写入并删除文件。
///
/// 覆盖清单（本项目实际含凭据的本地文件）：
/// - 流媒体服务器凭据 [streamingServersPath]（明文 password / accessToken）
/// - 第三方账号会话 [sessionStorePath]（网易云 cookies + 酷狗 token）
/// - 本地用户库 [userDbPath]（Subsonic 账号与收藏）
///
/// 所有销毁均要求输入确认词（settingsSecurityConfirmWord）二次确认；
/// 曲库 library.db / 历史 history.db / 下载文件不在销毁范围。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apis/netease/api.dart' show nmClearNeteaseCookies;
import '../../l10n/l10n.dart';
import '../../services/security/data_destroyer.dart';
import '../../services/streaming/streaming_provider.dart';
import '../../services/streaming/streaming_store.dart';
import '../../stores/providers.dart';
import '../../widgets/common/toast.dart';
import '../../widgets/dialogs/s_dialog.dart';
import '../../widgets/player/s_controls.dart';
import 'settings_widgets.dart';

class SecuritySection extends ConsumerStatefulWidget {
  const SecuritySection({super.key});

  @override
  ConsumerState<SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends ConsumerState<SecuritySection> {
  int _streamingBytes = 0;
  int _streamingCount = 0;
  int _sessionBytes = 0;
  bool _neteaseOnline = false;
  bool _kugouOnline = false;
  int _userDbBytes = 0;

  bool get _hasStreaming => _streamingBytes > 0;
  bool get _hasSession => _sessionBytes > 0 || _neteaseOnline || _kugouOnline;
  bool get _hasUserDb => _userDbBytes > 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// 重算统计：文件大小 + 登录态（销毁行是否可用的依据）。
  void _refresh() {
    final streaming = File(streamingServersPath());
    final session = File(sessionStorePath());
    final userDb = File(userDbPath());
    setState(() {
      _streamingBytes = streaming.existsSync() ? streaming.lengthSync() : 0;
      _streamingCount = _streamingBytes > 0
          ? StreamingStore.load().servers.length
          : 0;
      _sessionBytes = session.existsSync() ? session.lengthSync() : 0;
      _neteaseOnline = ref.read(neteaseAuthProvider) != null;
      _kugouOnline = ref.read(kugouApiProvider).isLoggedIn;
      _userDbBytes = userDb.existsSync() ? userDb.lengthSync() : 0;
    });
  }

  // ── 主动失效 token + 清内存登录态 ──────────────────────────────
  //
  // 顺序：先调平台登出 API（尽力而为，离线/失败不阻断）→ 本地兜底清
  // 会话 → 置空登录态（bootstrap 监听会自动向下载引擎重注空 cookie）。

  Future<void> _revokeNetease() async {
    try {
      await ref.read(neteaseApiProvider).logout();
    } catch (_) {
      // 离线等失败：本地兜底清会话（文件随后被覆盖删除）
      try {
        nmClearNeteaseCookies();
      } catch (_) {}
    }
  }

  Future<void> _revokeAll() async {
    await _revokeNetease();
    ref.read(kugouApiProvider).clearSession();
    ref.read(neteaseAuthProvider.notifier).clear();
    await ref.read(streamingProvider.notifier).clearAll();
  }

  // ── 确认词弹窗（输入匹配才放行，防误触不可逆操作）───────────────

  Future<bool?> _confirmShred(BuildContext context, String title, String desc) {
    final l10n = context.l10n;
    final word = l10n.settingsSecurityConfirmWord;
    return SDialog.show<bool>(
      context,
      title: title,
      description: desc,
      child: _WordConfirmField(
        word: word,
        hint: l10n.settingsSecurityConfirmHint(word),
        cancelLabel: l10n.commonCancel,
        confirmLabel: l10n.settingsSecurityDestroy,
      ),
    );
  }

  // ── 单项销毁 ───────────────────────────────────────────────────

  Future<void> _destroyStreaming() async {
    final l10n = context.l10n;
    final ok = await _confirmShred(
      context,
      l10n.settingsSecurityConfirmTitle(l10n.settingsSecurityStreaming),
      l10n.settingsSecurityConfirmDesc(l10n.settingsSecurityConfirmWord),
    );
    if (ok != true || !context.mounted) return;
    await ref.read(streamingProvider.notifier).clearAll();
    final r = destroySensitiveFiles([streamingServersPath()]);
    _afterDestroyed(l10n.settingsSecurityStreaming, r);
  }

  Future<void> _destroySession() async {
    final l10n = context.l10n;
    final ok = await _confirmShred(
      context,
      l10n.settingsSecurityConfirmTitle(l10n.settingsSecuritySession),
      l10n.settingsSecurityConfirmDesc(l10n.settingsSecurityConfirmWord),
    );
    if (ok != true || !context.mounted) return;
    await _revokeAll();
    final r = destroySensitiveFiles([sessionStorePath()]);
    _afterDestroyed(l10n.settingsSecuritySession, r);
  }

  Future<void> _destroyUserDb() async {
    final l10n = context.l10n;
    final ok = await _confirmShred(
      context,
      l10n.settingsSecurityConfirmTitle(l10n.settingsSecurityUserDb),
      l10n.settingsSecurityConfirmDesc(l10n.settingsSecurityConfirmWord),
    );
    if (ok != true || !context.mounted) return;
    final r = destroySensitiveFiles(sqliteFilePaths(userDbPath()));
    _afterDestroyed(l10n.settingsSecurityUserDb, r);
  }

  /// 一键销毁全部（更严格的确认文案）。
  Future<void> _destroyAll() async {
    final l10n = context.l10n;
    final ok = await _confirmShred(
      context,
      l10n.settingsSecurityConfirmAllTitle,
      l10n.settingsSecurityConfirmDesc(l10n.settingsSecurityConfirmWord),
    );
    if (ok != true || !context.mounted) return;
    await _revokeAll();
    final r = destroySensitiveFiles([
      streamingServersPath(),
      sessionStorePath(),
      ...sqliteFilePaths(userDbPath()),
    ]);
    _afterDestroyed(null, r);
  }

  void _afterDestroyed(String? name, List<ShredResult> results) {
    _refresh();
    final failed = results
        .where((r) => r.existed && !r.shredded)
        .map((r) => r.path);
    if (!mounted) return;
    final l10n = context.l10n;
    if (failed.isNotEmpty) {
      // 核心兜底仍失败（文件被占用等）→ 明确告知残留路径
      toast(
        l10n.toastSecurityDestroyFailed(failed.join(', ')),
        type: ToastType.error,
      );
      return;
    }
    toast(
      name == null
          ? l10n.toastSecurityAllDestroyed
          : l10n.toastSecurityDestroyed(name),
      type: ToastType.success,
    );
  }

  // ── UI ──────────────────────────────────────────────────────────

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String info,
    required bool enabled,
    required VoidCallback onDestroy,
  }) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return SettingTile(
      icon: icon,
      title: title,
      subtitle: info,
      trailing: IconButton(
        tooltip: l10n.settingsSecurityDestroy,
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        onPressed: enabled ? onDestroy : null,
        icon: Icon(
          Icons.delete_forever_outlined,
          color: enabled
              ? scheme.error
              : scheme.onSurface.withValues(alpha: 0.25),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final f = _formatBytes;
    final hasAny = _hasStreaming || _hasSession || _hasUserDb;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsSecuritySection,
          note: l10n.settingsSecurityNote,
          children: [
            // 操作行：刷新 + 一键销毁全部
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: Row(
                children: [
                  SButton(
                    label: l10n.settingsCacheRefresh,
                    icon: Icons.refresh,
                    variant: SButtonVariant.ghost,
                    size: SButtonSize.small,
                    onPressed: _refresh,
                  ),
                  const Spacer(),
                  SButton(
                    label: l10n.settingsSecurityDestroyAll,
                    icon: Icons.delete_sweep_outlined,
                    variant: SButtonVariant.error,
                    size: SButtonSize.small,
                    onPressed: hasAny ? _destroyAll : null,
                  ),
                ],
              ),
            ),
            _row(
              context,
              icon: Icons.dns_outlined,
              title: l10n.settingsSecurityStreaming,
              info:
                  '${streamingServersPath()}\n${f(_streamingBytes)} · ${l10n.settingsSecurityStreamingCount(_streamingCount)} · ${l10n.settingsSecurityStreamingDesc}',
              enabled: _hasStreaming,
              onDestroy: _destroyStreaming,
            ),
            _row(
              context,
              icon: Icons.account_circle_outlined,
              title: l10n.settingsSecuritySession,
              info:
                  '${sessionStorePath()}\n${f(_sessionBytes)} · ${l10n.settingsSecuritySessionDesc}'
                  '${_neteaseOnline || _kugouOnline ? ' · ${l10n.settingsSecurityLoggedIn}' : ''}',
              enabled: _hasSession,
              onDestroy: _destroySession,
            ),
            _row(
              context,
              icon: Icons.storage_outlined,
              title: l10n.settingsSecurityUserDb,
              info:
                  '${userDbPath()}\n${f(_userDbBytes)} · ${l10n.settingsSecurityUserDbDesc}',
              enabled: _hasUserDb,
              onDestroy: _destroyUserDb,
            ),
          ],
        ),
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
  }
}

/// 确认词输入区（SDialog child）：输入与确认词一致才启用「销毁」按钮。
class _WordConfirmField extends StatefulWidget {
  const _WordConfirmField({
    required this.word,
    required this.hint,
    required this.cancelLabel,
    required this.confirmLabel,
  });

  final String word;
  final String hint;
  final String cancelLabel;
  final String confirmLabel;

  @override
  State<_WordConfirmField> createState() => _WordConfirmFieldState();
}

class _WordConfirmFieldState extends State<_WordConfirmField> {
  final TextEditingController _ctrl = TextEditingController();
  bool _matched = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _ctrl,
          autofocus: true,
          onChanged: (v) => setState(() => _matched = v == widget.word),
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: widget.hint,
            isDense: true,
            errorText: _matched ? null : ' ',
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: scheme.error),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: scheme.outlineVariant),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SButton(
              label: widget.cancelLabel,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: () => Navigator.of(context).pop(false),
            ),
            const SizedBox(width: 10),
            SButton(
              label: widget.confirmLabel,
              variant: SButtonVariant.error,
              size: SButtonSize.small,
              onPressed: _matched
                  ? () => Navigator.of(context).pop(true)
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}
