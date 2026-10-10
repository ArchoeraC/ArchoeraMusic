// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 网易云歌单详情的管理动作（对齐原项目 Collection.vue 的订阅按钮 + more 菜单）。
///
/// - 非自建歌单：收藏 / 取消收藏按钮；
/// - 自建歌单：更多菜单（编辑名称/简介、删除歌单）。
///
/// 全部经 [neteaseUserPlaylistsProvider] 写入并联动收藏页刷新。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../stores/netease_user_playlists.dart';
import '../../stores/providers.dart';
import '../common/toast.dart';
import '../player/s_controls.dart';
import 's_context_menu.dart';
import 's_dialog.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 歌单详情头部动作（收藏 / 编辑 / 删除）。
///
/// [onDeleted] 在删除成功后回调（详情弹窗据此关闭自身）。
class PlaylistHeaderActions extends ConsumerStatefulWidget {
  const PlaylistHeaderActions({
    super.key,
    required this.playlistId,
    this.playlistName,
    this.onDeleted,
    this.onMetaUpdated,
  });

  final String playlistId;

  /// 当前歌单名（编辑时的回退标题）。
  final String? playlistName;
  final VoidCallback? onDeleted;
  final VoidCallback? onMetaUpdated;

  @override
  ConsumerState<PlaylistHeaderActions> createState() =>
      _PlaylistHeaderActionsState();
}

class _PlaylistHeaderActionsState extends ConsumerState<PlaylistHeaderActions> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (ref.read(neteaseAuthProvider) != null) {
      ref.read(neteaseUserPlaylistsProvider.notifier).ensureLoaded();
    }
  }

  Future<void> _toggleSubscribe(bool subscribed) async {
    if (_busy) return;
    setState(() => _busy = true);
    final l10n = context.l10n;
    try {
      await ref
          .read(neteaseUserPlaylistsProvider.notifier)
          .subscribe(widget.playlistId, subscribe: !subscribed);
      if (!mounted) return;
      toast(subscribed ? l10n.playlistUncollectDone : l10n.playlistCollectDone);
    } catch (_) {
      if (mounted) toast(l10n.playlistCollectFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    final ok = await showPlaylistEditDialog(
      context,
      playlistId: widget.playlistId,
      fallbackName: widget.playlistName,
    );
    if (ok && mounted) widget.onMetaUpdated?.call();
  }

  Future<void> _delete() async {
    final store = ref.read(neteaseUserPlaylistsProvider);
    final name =
        store.findById(widget.playlistId)?.name ?? widget.playlistName ?? '';
    final l10n = context.l10n;
    final confirmed = await SDialog.show<bool>(
      context,
      title: l10n.playlistDeleteTitle,
      description: l10n.playlistDeleteConfirm(name: name),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.commonDelete,
          variant: SButtonVariant.error,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
      child: const SizedBox.shrink(),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(neteaseUserPlaylistsProvider.notifier)
          .remove(widget.playlistId);
      if (!mounted) return;
      toast(l10n.playlistDeleteDone);
      widget.onDeleted?.call();
    } catch (_) {
      if (mounted) toast(l10n.playlistDeleteFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openMenu(BuildContext btnCtx) {
    final box = btnCtx.findRenderObject() as RenderBox?;
    final pos = box == null
        ? Offset.zero
        : box.localToGlobal(box.size.bottomRight(Offset.zero));
    final l10n = context.l10n;
    SContextMenu.show(
      btnCtx,
      position: pos,
      items: [
        SContextMenuItem(
          label: l10n.playlistEditTitle,
          icon: EtaIcons.editOutline,
          onTap: _busy ? null : _edit,
        ),
        SContextMenuItem(
          label: l10n.playlistDeleteTitle,
          icon: EtaIcons.deleteOutline,
          danger: true,
          onTap: _busy ? null : _delete,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(neteaseAuthProvider) != null;
    if (!loggedIn) return const SizedBox.shrink();
    final store = ref.watch(neteaseUserPlaylistsProvider);
    // 未加载完成时不显示（避免自建歌单短暂显示为「收藏」）。
    if (!store.loaded) {
      return _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const SizedBox.shrink();
    }
    // 「我喜欢的音乐」不提供管理动作（删除会清空红心歌单）。
    if (widget.playlistId == store.likedPlaylistId) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;

    if (store.isOwned(widget.playlistId)) {
      return Builder(
        builder: (btnCtx) => IconButton(
          tooltip: l10n.commonMore,
          visualDensity: VisualDensity.compact,
          onPressed: _busy ? null : () => _openMenu(btnCtx),
          icon: const Icon(EtaIcons.dotsVertical, size: 20),
        ),
      );
    }

    final subscribed = store.isSubscribed(widget.playlistId);
    return SButton(
      label: subscribed ? l10n.playlistCollected : l10n.playlistCollect,
      icon: subscribed ? EtaIcons.heart : EtaIcons.heartOutline,
      variant: subscribed ? SButtonVariant.secondary : SButtonVariant.primary,
      size: SButtonSize.small,
      loading: _busy,
      onPressed: _busy ? null : () => _toggleSubscribe(subscribed),
    );
  }
}

/// 弹出「编辑歌单」弹窗；保存成功返回 true。
Future<bool> showPlaylistEditDialog(
  BuildContext context, {
  required String playlistId,
  String? fallbackName,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    useRootNavigator: false,
    builder: (_) =>
        _PlaylistEditDialog(playlistId: playlistId, fallbackName: fallbackName),
  );
  return result == true;
}

class _PlaylistEditDialog extends ConsumerStatefulWidget {
  const _PlaylistEditDialog({required this.playlistId, this.fallbackName});

  final String playlistId;
  final String? fallbackName;

  @override
  ConsumerState<_PlaylistEditDialog> createState() =>
      _PlaylistEditDialogState();
}

class _PlaylistEditDialogState extends ConsumerState<_PlaylistEditDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final item = ref
        .read(neteaseUserPlaylistsProvider)
        .findById(widget.playlistId);
    _nameCtrl = TextEditingController(
      text: item?.name ?? widget.fallbackName ?? '',
    );
    _descCtrl = TextEditingController(text: item?.description ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(neteaseUserPlaylistsProvider.notifier)
          .updateMeta(
            widget.playlistId,
            name: name,
            description: _descCtrl.text.trim(),
          );
      if (!mounted) return;
      toast(context.l10n.playlistEditDone);
      Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) toast(context.l10n.playlistEditFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SDialog(
      title: l10n.playlistEditTitle,
      width: 420,
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.commonSave,
          variant: SButtonVariant.primary,
          loading: _busy,
          onPressed: _busy ? null : _save,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SInput(
            controller: _nameCtrl,
            hintText: l10n.playlistEditName,
            autofocus: true,
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          SInput(controller: _descCtrl, hintText: l10n.playlistEditDescHint),
        ],
      ),
    );
  }
}
