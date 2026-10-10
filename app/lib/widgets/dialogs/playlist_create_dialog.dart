// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 新建歌单弹窗（网易云，对齐原项目 PlaylistCreateDialog.vue）。
///
/// 名称 + 「设为私密」（privacy 0 / 10）两项；提交走
/// [NeteaseUserPlaylistsNotifier.create]，成功后刷新用户歌单并联动收藏页。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../stores/netease_user_playlists.dart';
import '../common/toast.dart';
import '../player/s_controls.dart';
import 's_dialog.dart';

/// 弹出「新建歌单」弹窗。
///
/// 成功返回新歌单 id；取消 / 失败返回 null。`quietSubmit` 为 true 时交由调用方
/// 提示（如歌单选择器加入歌曲后再统一提示）。
Future<String?> showPlaylistCreateDialog(
  BuildContext context, {
  bool quietSubmit = false,
}) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    useRootNavigator: false,
    builder: (_) => _PlaylistCreateDialog(quietSubmit: quietSubmit),
  );
}

class _PlaylistCreateDialog extends ConsumerStatefulWidget {
  const _PlaylistCreateDialog({required this.quietSubmit});

  final bool quietSubmit;

  @override
  ConsumerState<_PlaylistCreateDialog> createState() =>
      _PlaylistCreateDialogState();
}

class _PlaylistCreateDialogState extends ConsumerState<_PlaylistCreateDialog> {
  final _nameCtrl = TextEditingController();
  bool _privacy = false;
  bool _busy = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final id = await ref
          .read(neteaseUserPlaylistsProvider.notifier)
          .create(name, privacy: _privacy ? 10 : 0);
      if (!mounted) return;
      if (!widget.quietSubmit) toast(context.l10n.playlistCreateDone);
      Navigator.of(context).pop(id);
    } catch (_) {
      if (mounted) toast(context.l10n.playlistCreateFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return SDialog(
      title: l10n.playlistCreateTitle,
      width: 420,
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        SButton(
          label: l10n.playlistCreateSubmit,
          variant: SButtonVariant.primary,
          loading: _busy,
          onPressed: _busy ? null : _submit,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SInput(
            controller: _nameCtrl,
            hintText: l10n.playlistCreateNameHint,
            autofocus: true,
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.playlistCreatePrivacy,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Text(
                      l10n.playlistCreatePrivacyHint,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _privacy,
                onChanged: _busy ? null : (v) => setState(() => _privacy = v),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
