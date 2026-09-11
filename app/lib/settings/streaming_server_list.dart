// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 设置「媒体源」分类内容：流媒体服务器列表（对齐 StreamingServerList.vue）。
///
/// 顶部说明条 + 添加按钮；服务器卡片列表（名称 / 类型 / 激活状态 /
/// username@host / 最近连接时间 + 连接/断开/编辑/删除操作）；空态引导。
/// 添加/编辑走 [SDialog] 表单（类型 / 名称 / 主机 / 端口 / HTTPS /
/// 本机服务端 / 用户名 / 密码 + 测试连接），删除有确认弹窗。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/streaming/streaming_provider.dart';
import '../services/streaming/streaming_types.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/dialogs/s_dialog.dart';
import '../widgets/common/toast.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'streaming_server/streaming_server_list_view.dart';
part 'streaming_server/streaming_server_form_view.dart';

/// 服务器类型展示名（品牌名不翻译）。
const streamingTypeLabels = <StreamingServerType, String>{
  StreamingServerType.navidrome: 'Navidrome',
  StreamingServerType.jellyfin: 'Jellyfin',
  StreamingServerType.emby: 'Emby',
  StreamingServerType.opensubsonic: 'OpenSubsonic',
  StreamingServerType.airsonic: 'Airsonic',
  StreamingServerType.gonic: 'Gonic',
  StreamingServerType.lms: 'LMS',
  StreamingServerType.subsonic: 'Subsonic',
};

/// 成功绿（已连接 / 测试通过）。
const _okGreen = Color(0xFF34C759);

/// 警告橙（未连接 / 连接中）。
const _warnOrange = Color(0xFFFFB340);

/// 卡片式容器装饰（浅底色 + 圆角 + 细边框）。
BoxDecoration cardDecoration(ColorScheme scheme) {
  return BoxDecoration(
    color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
    borderRadius: BorderRadius.circular(AppRadius.card),
    border: Border.all(color: scheme.outline.withValues(alpha: 0.3)),
  );
}

/// 设置「媒体源」内容（嵌入设置弹窗）。
class StreamingServerList extends ConsumerStatefulWidget {
  const StreamingServerList({super.key});

  @override
  ConsumerState<StreamingServerList> createState() =>
      _StreamingServerListState();
}

class _StreamingServerListState extends ConsumerState<StreamingServerList> {
  /// 正在切换连接的服务器 id（按钮 loading）。
  String? _switchingId;

  @override
  Widget build(BuildContext context) => _buildStreamingServerList(context);

  /// 发起连接：按钮 loading → 切换活动服务器 → 结果 toast。
  Future<void> _connect(
    StreamingNotifier notifier,
    AppLocalizations l10n,
    StreamingServerConfig cfg,
  ) async {
    setState(() => _switchingId = cfg.id);
    await notifier.setActiveServer(cfg.id);
    if (!mounted) return;
    setState(() => _switchingId = null);
    final s = ref.read(streamingProvider);
    if (s.connected && s.activeServerId == cfg.id) {
      toast(l10n.streamingToastConnected(cfg.name));
    } else {
      toast(
        s.connectionError ?? l10n.streamingServerConnectFailed,
        type: ToastType.error,
      );
    }
  }

  /// 断开连接 + 结果 toast。
  Future<void> _disconnect(
    StreamingNotifier notifier,
    AppLocalizations l10n,
  ) async {
    await notifier.disconnect();
    if (!mounted) return;
    toast(l10n.streamingToastDisconnected);
  }

  Future<void> _confirmRemove(
    BuildContext context,
    AppLocalizations l10n,
    StreamingServerConfig cfg,
    StreamingNotifier notifier,
  ) async {
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.streamingServerDeleteConfirmTitle,
      child: Text(
        l10n.streamingServerDeleteConfirm(cfg.name),
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.5,
        ),
      ),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.commonConfirm,
          icon: EtaIcons.deleteOutline,
          variant: SButtonVariant.error,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok != true || !context.mounted) return;
    await notifier.removeServer(cfg.id);
    if (!context.mounted) return;
    toast(l10n.streamingServerRemoved);
  }

  /// 打开添加 / 编辑表单弹窗。
  Future<void> _showServerForm(
    BuildContext context,
    AppLocalizations l10n, {
    StreamingServerConfig? existing,
  }) async {
    await SDialog.show(
      context,
      title: existing == null
          ? l10n.streamingServerAdd
          : l10n.streamingServerEdit,
      width: 520,
      child: _ServerForm(existing: existing),
    );
  }

  static String _formatDateTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${pad(dt.month)}-${pad(dt.day)} '
        '${pad(dt.hour)}:${pad(dt.minute)}';
  }
}

/// 小型类型 / 状态标签。
class _TypeTag extends StatelessWidget {
  const _TypeTag({required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: c),
      ),
    );
  }
}

/// 服务器表单（添加 / 编辑共用）：字段 + 测试连接 + 保存。
class _ServerForm extends ConsumerStatefulWidget {
  const _ServerForm({this.existing});

  final StreamingServerConfig? existing;

  @override
  ConsumerState<_ServerForm> createState() => _ServerFormState();
}

class _ServerFormState extends ConsumerState<_ServerForm> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;
  late StreamingServerType _type;
  late bool _isLocal;
  late bool _useHttps;

  bool _testing = false;
  bool _submitting = false;
  StreamingPingResult? _testResult;
  String? _formError;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _type = e?.type ?? StreamingServerType.navidrome;
    _isLocal = e?.isArchoeraServer ?? false;
    _useHttps = e?.useHttps ?? false;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _hostCtrl = TextEditingController(text: e?.host ?? '');
    _portCtrl = TextEditingController(text: e?.port?.toString() ?? '');
    _userCtrl = TextEditingController(text: e?.username ?? '');
    _passCtrl = TextEditingController(text: e?.password ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  String? _validate(AppLocalizations l10n) {
    if (_nameCtrl.text.trim().isEmpty) {
      return l10n.streamingServerErrorNameEmpty;
    }
    if (_hostCtrl.text.trim().isEmpty) {
      return l10n.streamingServerErrorHostEmpty;
    }
    final port = _portCtrl.text.trim();
    if (port.isNotEmpty) {
      final p = int.tryParse(port);
      if (p == null || p < 1 || p > 65535) {
        return l10n.streamingServerErrorPortInvalid;
      }
    }
    if (_userCtrl.text.trim().isEmpty) {
      return l10n.streamingServerErrorUsernameEmpty;
    }
    if (_passCtrl.text.isEmpty) return l10n.streamingServerErrorPasswordEmpty;
    return null;
  }

  StreamingServerInput get _input => StreamingServerInput(
    name: _nameCtrl.text.trim(),
    type: _type,
    host: _isLocal ? 'localhost' : _hostCtrl.text.trim(),
    port: int.tryParse(_portCtrl.text.trim()),
    isArchoeraServer: _isLocal,
    useHttps: _useHttps,
    username: _userCtrl.text.trim(),
    password: _passCtrl.text,
  );

  void _setFormError(String? error) {
    setState(() => _formError = error);
  }

  void _setTestingState(bool testing, {StreamingPingResult? result}) {
    setState(() {
      _testing = testing;
      _testResult = result;
    });
  }

  void _setSubmittingState(bool submitting) {
    setState(() => _submitting = submitting);
  }

  void _setLocal(bool value) {
    setState(() => _isLocal = value);
  }

  void _setHttps(bool value) {
    setState(() => _useHttps = value);
  }

  void _setType(StreamingServerType value) {
    setState(() => _type = value);
  }

  Future<void> _handleTest(AppLocalizations l10n) async {
    final invalid = _validate(l10n);
    if (invalid != null) {
      _setFormError(invalid);
      _setTestingState(false, result: null);
      return;
    }
    _setFormError(null);
    _setTestingState(true, result: null);
    final res = await ref
        .read(streamingProvider.notifier)
        .testConnection(_input);
    if (!mounted) return;
    _setTestingState(false, result: res);
  }

  Future<void> _handleSubmit(AppLocalizations l10n) async {
    final invalid = _validate(l10n);
    if (invalid != null) {
      _setFormError(invalid);
      return;
    }
    _setFormError(null);
    _setSubmittingState(true);
    final notifier = ref.read(streamingProvider.notifier);
    final existing = widget.existing;
    if (existing == null) {
      await notifier.addServer(_input);
    } else {
      await notifier.updateServer(existing.id, _input);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    toast(
      existing == null
          ? l10n.streamingServerAdded
          : l10n.streamingServerUpdated,
    );
  }

  @override
  Widget build(BuildContext context) => _buildServerForm(context);
}

/// 紧凑开关行。
class _SwitchTile extends StatelessWidget {
  const _SwitchTile({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      alignment: Alignment.centerLeft,
      child: Switch(
        value: value,
        onChanged: onChanged,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
