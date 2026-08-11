/// 设置「媒体源」分类内容：流媒体服务器列表（对齐 StreamingServerList.vue）。
///
/// 顶部说明条 + 添加按钮；服务器卡片列表（名称 / 类型 / 激活状态 /
/// username@host / 最近连接时间 + 连接/断开/编辑/删除操作）；空态引导。
/// 添加/编辑走 [SDialog] 表单（类型 / 名称 / 主机 / 端口 / HTTPS /
/// 本机服务端 / 用户名 / 密码 + 测试连接），删除有确认弹窗。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/streaming/streaming_provider.dart';
import '../services/streaming/streaming_types.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/dialogs/s_dialog.dart';
import '../widgets/common/toast.dart';

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
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(streamingProvider);
    final notifier = ref.read(streamingProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部说明条 + 添加按钮
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: cardDecoration(scheme),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.streamingHint,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.streamingHintDetail,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SButton(
                label: l10n.streamingServerAdd,
                icon: Icons.add,
                variant: SButtonVariant.secondary,
                size: SButtonSize.small,
                onPressed: () => _showServerForm(context, l10n),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (state.servers.isEmpty)
          _buildEmpty(scheme, l10n)
        else
          ...state.servers.map(
            (cfg) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildCard(scheme, l10n, cfg, state, notifier),
            ),
          ),
      ],
    );
  }

  Widget _buildEmpty(ColorScheme scheme, AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: cardDecoration(scheme),
      child: Column(
        children: [
          Icon(
            Icons.dns_outlined,
            size: 30,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.streamingEmptyNoServer,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.streamingEmptyAddHint,
            style: TextStyle(
              fontSize: 11.5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(
    ColorScheme scheme,
    AppLocalizations l10n,
    StreamingServerConfig cfg,
    StreamingState state,
    StreamingNotifier notifier,
  ) {
    final isActive = state.activeServerId == cfg.id;
    final isConnected = isActive && state.connected;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: cardDecoration(scheme),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 状态点
          _buildStatusDot(scheme, state, isActive, isConnected),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        cfg.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _TypeTag(
                      label: streamingTypeLabels[cfg.type] ?? cfg.type.name,
                    ),
                    if (isActive) _buildStatusTag(l10n, state, isConnected),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${cfg.username}@${cfg.host}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                  ),
                ),
                if (cfg.lastConnected != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${l10n.streamingServerLastConnected}: '
                    '${_formatDateTime(cfg.lastConnected!)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 操作按钮
          _buildActions(context, l10n, cfg, state, notifier),
        ],
      ),
    );
  }

  /// 状态圆点：连接成功（绿）/ 连接错误（红）/ 未连接（橙）。
  Widget _buildStatusDot(
    ColorScheme scheme,
    StreamingState state,
    bool isActive,
    bool isConnected,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isConnected
              ? _okGreen
              : (state.connectionError != null && isActive)
              ? scheme.error
              : _warnOrange,
        ),
      ),
    );
  }

  /// 激活状态标签（连接中 / 已连接 / 已断开）。
  Widget _buildStatusTag(
    AppLocalizations l10n,
    StreamingState state,
    bool isConnected,
  ) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: _TypeTag(
        label: isConnected
            ? l10n.streamingServerConnected
            : (state.connecting
                  ? l10n.commonLoading
                  : l10n.streamingServerDisconnected),
        color: isConnected ? _okGreen : _warnOrange,
      ),
    );
  }

  /// 卡片右侧操作按钮（连接/断开 + 编辑/删除）。
  Widget _buildActions(
    BuildContext context,
    AppLocalizations l10n,
    StreamingServerConfig cfg,
    StreamingState state,
    StreamingNotifier notifier,
  ) {
    final isActive = state.activeServerId == cfg.id;
    final isConnected = isActive && state.connected;
    final connecting = isActive && state.connecting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (isActive && isConnected)
          SButton(
            label: l10n.streamingServerDisconnect,
            icon: Icons.link_off,
            variant: SButtonVariant.secondary,
            size: SButtonSize.small,
            onPressed: () => _disconnect(notifier, l10n),
          )
        else
          SButton(
            label: l10n.streamingServerConnect,
            icon: Icons.link,
            variant: SButtonVariant.secondary,
            size: SButtonSize.small,
            loading: _switchingId == cfg.id || connecting,
            onPressed: () => _connect(notifier, l10n, cfg),
          ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SButton(
              label: l10n.streamingServerEdit,
              icon: Icons.edit_outlined,
              variant: SButtonVariant.ghost,
              size: SButtonSize.small,
              onPressed: () => _showServerForm(context, l10n, existing: cfg),
            ),
            const SizedBox(width: 6),
            SButton(
              label: l10n.commonDelete,
              icon: Icons.delete_outline,
              variant: SButtonVariant.ghost,
              size: SButtonSize.small,
              onPressed: () => _confirmRemove(context, l10n, cfg, notifier),
            ),
          ],
        ),
      ],
    );
  }

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
          icon: Icons.delete_outline,
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

  Future<void> _handleTest(AppLocalizations l10n) async {
    final invalid = _validate(l10n);
    if (invalid != null) {
      setState(() {
        _formError = invalid;
        _testResult = null;
      });
      return;
    }
    setState(() {
      _formError = null;
      _testResult = null;
      _testing = true;
    });
    final res = await ref
        .read(streamingProvider.notifier)
        .testConnection(_input);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = res;
    });
  }

  Future<void> _handleSubmit(AppLocalizations l10n) async {
    final invalid = _validate(l10n);
    if (invalid != null) {
      setState(() => _formError = invalid);
      return;
    }
    setState(() {
      _formError = null;
      _submitting = true;
    });
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
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final testOk = _testResult?.ok ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _field(scheme, l10n.streamingServerType, child: _typeDropdown(scheme)),
        _field(
          scheme,
          l10n.streamingServerName,
          child: SInput(
            controller: _nameCtrl,
            hintText: l10n.streamingServerNamePlaceholder,
          ),
        ),
        _field(
          scheme,
          l10n.streamingServerHost,
          child: SInput(
            controller: _hostCtrl,
            hintText: l10n.streamingServerHostPlaceholder,
            enabled: !_isLocal,
          ),
        ),
        if (!_isLocal) ...[
          Row(
            children: [
              Expanded(
                child: _field(
                  scheme,
                  l10n.streamingServerPort,
                  child: SInput(
                    controller: _portCtrl,
                    hintText: '443',
                    keyboardType: TextInputType.number,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _field(
                  scheme,
                  'HTTPS',
                  child: _SwitchTile(
                    value: _useHttps,
                    onChanged: (v) => setState(() => _useHttps = v),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              l10n.streamingServerPortNote,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
        _field(
          scheme,
          l10n.streamingServerLocalTitle,
          child: _SwitchTile(
            value: _isLocal,
            onChanged: (v) => setState(() => _isLocal = v),
          ),
        ),
        if (_isLocal)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              l10n.streamingServerLocalDesc,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
        _field(
          scheme,
          l10n.streamingServerUsername,
          child: SInput(controller: _userCtrl),
        ),
        _field(
          scheme,
          l10n.streamingServerPassword,
          child: SInput(controller: _passCtrl, obscureText: true),
        ),
        // 校验错误
        if (_formError != null)
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _formError!,
              style: TextStyle(fontSize: 12, color: scheme.error),
            ),
          ),
        // 测试结果
        if (_testResult != null) _buildTestResult(scheme, l10n, testOk),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SButton(
              label: l10n.commonCancel,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: _submitting || _testing
                  ? null
                  : () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 10),
            SButton(
              label: l10n.streamingServerTest,
              icon: Icons.wifi_tethering,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              loading: _testing,
              onPressed: _submitting ? null : () => _handleTest(l10n),
            ),
            const SizedBox(width: 10),
            SButton(
              label: l10n.commonSave,
              icon: Icons.check,
              variant: SButtonVariant.primary,
              size: SButtonSize.small,
              loading: _submitting,
              onPressed: _testing ? null : () => _handleSubmit(l10n),
            ),
          ],
        ),
      ],
    );
  }

  /// 测试结果展示区（成功 / 失败）。
  Widget _buildTestResult(
    ColorScheme scheme,
    AppLocalizations l10n,
    bool testOk,
  ) {
    final result = _testResult!;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: (testOk ? _okGreen : scheme.error).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                testOk ? Icons.check_circle : Icons.error,
                size: 14,
                color: testOk ? _okGreen : scheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  testOk
                      ? (result.version != null
                            ? '${l10n.streamingServerTestOk} · v${result.version}'
                            : l10n.streamingServerTestOk)
                      : l10n.streamingServerTestFail,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: testOk ? _okGreen : scheme.error,
                  ),
                ),
              ),
            ],
          ),
          if (result.error != null) ...[
            const SizedBox(height: 4),
            Text(
              result.error!,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _typeDropdown(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: DropdownButton<StreamingServerType>(
        value: _type,
        isDense: true,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(10),
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        icon: Icon(Icons.arrow_drop_down, color: scheme.onSurfaceVariant),
        onChanged: (v) {
          if (v != null) setState(() => _type = v);
        },
        items: [
          for (final t in StreamingServerType.values)
            DropdownMenuItem(
              value: t,
              child: Text(streamingTypeLabels[t] ?? t.name),
            ),
        ],
      ),
    );
  }

  Widget _field(ColorScheme scheme, String label, {required Widget child}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
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
