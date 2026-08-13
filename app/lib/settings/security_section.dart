/// 存储分类下的「安全销毁」危险区（敏感数据不可逆擦除）。
///
/// 对齐需求：必要情况下允许用户直接销毁敏感数据库 ——
/// 主动失效 token（网易云 /api/logout）+ 随机数据覆盖写入并删除文件。
///
/// 覆盖清单（本项目实际含凭据的本地文件）：
/// - 流媒体服务器凭据 [streamingServersPath]（password/accessToken 已由
///   凭据保险库 vault 加密存储，文件仅存非敏感字段）
/// - 第三方账号会话 [sessionStorePath]（网易云 cookies + 酷狗 token，
///   已由 vault 接管，此文件仅存历史明文用于迁移/兜底清理）
/// - 本地用户库 [userDbPath]（Subsonic 账号与收藏）
///
/// 所有销毁均要求输入确认词（settingsSecurityConfirmWord）二次确认；
/// 曲库 library.db / 历史 history.db / 下载文件不在销毁范围。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apis/netease/api.dart' show nmClearNeteaseCookies;
import '../../apis/runtime.dart' show getRuntime;
import '../../app/app_quit.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/security/data_destroyer.dart';
import '../../services/security/vault_process.dart';
import '../../services/streaming/streaming_provider.dart';
import '../../services/streaming/streaming_store.dart';
import '../../stores/app_prefs.dart';
import '../../stores/data_dir.dart';
import '../../stores/providers.dart';
import '../../stores/vault_session_store.dart';
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

  /// vault 份额锚定模式（`os` | `password` | `multiseal` | null=未初始化）。
  /// 驱动「设备绑定免密」开关状态；经 [VaultProcess.mode] 异步读取。
  String? _vaultMode;

  /// 设备绑定相关操作进行中（开关/管理行禁用防重入）。
  bool _deviceBusy = false;

  bool get _hasStreaming => _streamingBytes > 0;
  bool get _hasSession => _sessionBytes > 0 || _neteaseOnline || _kugouOnline;
  bool get _hasUserDb => _userDbBytes > 0;

  // ── 设备绑定（v3 增强项，opt-in，device-bound-vault-plan §7.3）──────

  bool get _isDeviceBound => _vaultMode == 'multiseal';

  /// 设备变更/熵损坏（v3 有口令封装）：会话/流媒体任一侧标记即需恢复。
  bool get _needsRecovery {
    final s = getRuntime().sessionStore;
    return (s is VaultSessionStore && s.needsRecovery) ||
        StreamingStore.needsRecovery;
  }

  /// 份额不配对（v4 后端指纹不符 / 份额缺失 / GCM 认证失败）：vault 无法
  /// 解密且数据不可恢复——显示红色横幅引导「销毁重建」（非恢复流，无口令
  /// 封装可解；不反复重试）。
  bool get _shareBroken {
    final s = getRuntime().sessionStore;
    return s is VaultSessionStore && s.shareBroken;
  }

  /// v2（口令模式）本会话已解锁：会话口令内存持有，可执行需要口令的操作
  /// （升级设备绑定、凭据持久化等）。
  bool get _v2Unlocked {
    final s = getRuntime().sessionStore;
    return s is VaultSessionStore && s.isV2Unlocked;
  }

  /// 切换条禁用的档位：busy 全禁；v2（口令模式）未解锁时回落 v1 / 升级
  /// v3 都需当前口令 → 灰显引导先解锁。v3 不回 v1 由点击时 toast 解释
  /// （保留可点，让用户知道为什么不能直达）。
  Set<String> get _disabledModes {
    if (_deviceBusy) return const {'os', 'password', 'multiseal'};
    if (_vaultMode == 'password' && !_v2Unlocked) {
      return const {'os', 'multiseal'};
    }
    return const {};
  }

  /// 凭据加密方案（'crypto'=LEGACY 单因子 / 'vault'=2-of-2 实验性）。
  /// 由 vault 实际模式推导（crypto → 'crypto'；os/password/multiseal → 'vault'；
  /// 未初始化 → prefs 偏好兜底，保证首次启动卡片有默认选中态）。
  String get _scheme {
    if (_vaultMode == 'crypto') return 'crypto';
    if (_vaultMode == 'os' ||
        _vaultMode == 'password' ||
        _vaultMode == 'multiseal') {
      return 'vault';
    }
    return ref.read(appPrefsProvider).credentialScheme;
  }

  /// 方案卡片点击分发：目标 == 当前 → 忽略；否则走 [_switchScheme] 互切。
  Future<void> _onSchemeSelected(String target) async {
    if (_deviceBusy || target == _scheme) return;
    await _switchScheme(target);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// 重算统计：文件大小 + 登录态（销毁行是否可用的依据）。
  void _refresh() {
    final streaming = File(streamingServersPath());
    final vault = File(vaultFilePath());
    final userDb = File(userDbPath());
    setState(() {
      _streamingBytes = streaming.existsSync() ? streaming.lengthSync() : 0;
      _streamingCount = _streamingBytes > 0
          ? StreamingStore.load().servers.length
          : 0;
      _sessionBytes = vault.existsSync() ? vault.lengthSync() : 0;
      _neteaseOnline = ref.read(neteaseAuthProvider) != null;
      _kugouOnline = ref.read(kugouApiProvider).isLoggedIn;
      _userDbBytes = userDb.existsSync() ? userDb.lengthSync() : 0;
    });
    _refreshVault();
  }

  /// 异步刷新 vault 模式（驱动设备绑定开关；失败保持上次状态）。
  Future<void> _refreshVault() async {
    String? mode;
    try {
      mode = await VaultProcess.mode(resolveDataDir());
    } catch (_) {
      // 二进制缺失等：开关按未初始化处理（可首启设备绑定）
    }
    if (!mounted || mode == _vaultMode) return;
    setState(() => _vaultMode = mode);
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
    // 先销毁 vault（删 OS 授权份额 + vault 文件，2-of-2 缺口 → 密文不可恢复），
    // 再覆盖删除历史明文会话文件（迁移失败残留时兜底）
    try {
      VaultProcess.destroy(resolveDataDir());
    } catch (_) {
      // 二进制缺失等：vault 文件仍在，交由下方 shred 覆盖删除
    }
    final r = destroySensitiveFiles([vaultFilePath(), sessionStorePath()]);
    _afterDestroyed(l10n.settingsSecuritySession, r);
  }

  /// 份额不配对（[shareBroken]）恢复动作：销毁 vault（弹确认）→ 引导重启。
  /// 重启后 vault 惰性重建（store 检测未初始化自动 init），重新登录即可——
  /// 不反复重试（不配对是确定性环境故障，非瞬时错误）。
  Future<void> _destroyBrokenVault() async {
    await _destroySession();
    if (!mounted) return;
    await _restartApp();
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
    try {
      VaultProcess.destroy(resolveDataDir());
    } catch (_) {}
    final r = destroySensitiveFiles([
      streamingServersPath(),
      vaultFilePath(),
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

  // ── 设备绑定操作（v3 增强项，opt-in，§7.3）───────────────────────

  /// 恢复口令输入弹窗。返回：
  ///   null = 用户取消；'' = 确认但未输入（仅 [optional] 场景=跳过）；
  ///   其他 = 确认输入的口令。
  Future<String?> _promptRecoveryPassword({
    required String title,
    required String description,
    String? hint,
    bool optional = false,
  }) {
    final l10n = context.l10n;
    return SDialog.show<String>(
      context,
      title: title,
      description: description,
      child: _RecoveryPasswordField(
        hint: hint ?? l10n.settingsDeviceBindRecoveryHint,
        optional: optional,
        skipLabel: l10n.settingsDeviceBindSkip,
        confirmLabel: l10n.commonConfirm,
      ),
    );
  }

  /// 开关 → 开启：隐私提示 → 可选恢复口令 → 按当前模式迁移：
  ///   未初始化 → init-device（首启设备绑定）；
  ///   v1（os）→ upgrade-device（K 不变、既有条目沿用，直接升 v3）；
  ///   v2（password，须本会话已解锁）→ upgrade-device(password=会话口令)。
  Future<void> _enableDeviceBind() async {
    final l10n = context.l10n;
    // 1) 显式隐私提示（设备指纹采集，opt-in 约束 §1.3）
    final privacyOk = await SDialog.show<bool>(
      context,
      title: l10n.settingsDeviceBindPrivacyTitle,
      description: l10n.settingsDeviceBindPrivacyDesc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsDeviceBindEnable,
          icon: Icons.security_outlined,
          variant: SButtonVariant.primary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (privacyOk != true || !mounted) return;
    // 2) 可选恢复口令（留空 = 不设口令，换机后 fail-closed）
    final res = await _promptRecoveryPassword(
      title: l10n.settingsDeviceBindRecoveryTitle,
      description: l10n.settingsDeviceBindRecoveryDesc,
      optional: true,
    );
    if (res == null || !mounted) return; // 取消
    final dataDir = resolveDataDir();
    setState(() => _deviceBusy = true);
    try {
      // 升级前排空持久化队列（同 _switchToPassword：防在途写落新布局失败）
      final s0 = getRuntime().sessionStore;
      if (s0 is VaultSessionStore) await s0.flush();
      await StreamingStore.flush();
      if (_vaultMode == null) {
        // 首启设备绑定（vault 尚未初始化）
        if (res.isEmpty) {
          await VaultProcess.initDevice(dataDir);
        } else {
          await VaultProcess.initDevice(dataDir, recoveryPassword: res);
        }
      } else {
        // 既有 vault 升级：v1（os）免口令；v2（password）须传本会话口令
        final s = getRuntime().sessionStore;
        final password = s is VaultSessionStore ? s.sessionPassword : null;
        if (res.isEmpty) {
          await VaultProcess.upgradeDevice(dataDir, password: password);
        } else {
          await VaultProcess.upgradeDevice(
            dataDir,
            recoveryPassword: res,
            password: password,
          );
        }
      }
      // 同步 store 内存态（v3 免密，无需口令）：切换条/持久化按新模式走
      final s = getRuntime().sessionStore;
      if (s is VaultSessionStore) s.syncMode('multiseal');
      StreamingStore.syncPasswordState(null);
      if (!mounted) return;
      if (await _promptRestartAfterModeChange() && mounted) {
        await _restartApp();
        return;
      }
      toast(l10n.toastDeviceBindEnabled, type: ToastType.success);
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
  }

  /// 开关 → 关闭（回落口令模式）：
  ///   有恢复口令封装 → 输入当前恢复口令授权（口令即回落后的 v2 会话口令）；
  ///   无（纯熵绑定，开启时免密）→ 直接设置新的 v2 解锁口令（免授权校验，
  ///   与「免密开启」对称——避免无口令用户被卡死）。
  Future<void> _disableDeviceBind() async {
    final l10n = context.l10n;
    final dataDir = resolveDataDir();
    // 先探测是否设置了恢复口令，决定弹「验证恢复口令」还是「设置新口令」
    final hasRecovery = await VaultProcess.hasRecovery(dataDir);
    if (!mounted) return;
    String? res;
    if (hasRecovery) {
      res = await _promptRecoveryPassword(
        title: l10n.settingsDeviceBindCloseTitle,
        description: l10n.settingsDeviceBindCloseConfirmDesc,
        hint: l10n.settingsDeviceBindCloseHint,
      );
      if (res == null || res.isEmpty || !context.mounted) return;
    } else {
      res = await _promptNewV2Password();
      if (res == null || res.isEmpty || !context.mounted) return;
    }
    setState(() => _deviceBusy = true);
    try {
      // 关闭前排空持久化队列（同 _switchToPassword：防在途写落新布局失败）
      final s0 = getRuntime().sessionStore;
      if (s0 is VaultSessionStore) await s0.flush();
      await StreamingStore.flush();
      final ok = await VaultProcess.clearDeviceSeal(dataDir, res);
      if (ok) {
        // 同步 store 内存态（v3 → v2，新会话口令 = 恢复口令/新设口令）：
        // 本会话保持解锁，切换条/持久化按口令模式走
        final s = getRuntime().sessionStore;
        if (s is VaultSessionStore) {
          s.syncMode('password', sessionPassword: res);
        }
        StreamingStore.syncPasswordState(res);
        if (!mounted) return;
        if (await _promptRestartAfterModeChange() && mounted) {
          await _restartApp();
          return;
        }
      }
      toast(
        ok ? l10n.toastDeviceBindClosed : l10n.toastDeviceBindRecoveryNeeded,
        type: ok ? ToastType.success : ToastType.warning,
      );
    } on VaultException catch (e) {
      // 口令错误（GCM 拒绝）等：明确提示不触发退避
      toast(
        l10n.toastDeviceBindCloseFailed(e.message),
        type: ToastType.error,
      );
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
  }

  /// 纯熵绑定（v3 开启未设恢复口令）关闭时的「设置新 v2 口令」弹窗：
  /// 复用 [SDialog] + [_NewPasswordField]（两次输入一致性校验）。
  Future<String?> _promptNewV2Password() {
    final l10n = context.l10n;
    return SDialog.show<String>(
      context,
      title: l10n.settingsVaultCloseV3PasswordTitle,
      description: l10n.settingsVaultCloseV3PasswordDesc,
      child: _NewPasswordField(
        newHint: l10n.settingsVaultSwitchToPasswordNewHint,
        confirmHint: l10n.settingsVaultSwitchToPasswordConfirmHint,
        mismatchText: l10n.settingsVaultSwitchToPasswordMismatch,
      ),
    );
  }

  /// 方案互切（crypto ↔ vault）：两种方案的加密数据结构不兼容，无法原地
  /// 迁移——销毁现有凭据库 → 按目标方案重建（cookie 全部丢失）→ 写回方案
  /// 偏好 → 冷切重启。方向警告：
  ///   vault：实验性方案（份额/口令/设备绑定任一环节异常都可能频繁丢 Cookie）；
  ///   统一：重建数据库（丢失全部已保存 Cookie）且必须冷启动。
  Future<void> _switchScheme(String target) async {
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.settingsSchemeSwitchTitle,
      description: [
        if (target == 'vault') l10n.settingsSchemeSwitchToVaultWarning,
        l10n.settingsSchemeSwitchRebuildDesc,
      ].join('\n\n'),
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.settingsSchemeSwitchKeep,
          variant: SButtonVariant.secondary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsSchemeSwitchConfirm,
          icon: Icons.sync_problem_outlined,
          variant: SButtonVariant.primary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok != true || !mounted) return;
    setState(() => _deviceBusy = true);
    try {
      // 排空持久化队列（防在途写落到销毁后的空库上）→ 销毁 → 按目标方案重建
      final s = getRuntime().sessionStore;
      if (s is VaultSessionStore) await s.flush();
      await StreamingStore.flush();
      VaultProcess.destroy(resolveDataDir());
      if (target == 'vault') {
        await VaultProcess.init(resolveDataDir());
      } else {
        await VaultProcess.initCrypto(resolveDataDir());
      }
      // 同步方案偏好（重启后惰性重建与 UI 显示一致）与内存态
      ref.read(appPrefsProvider.notifier).setCredentialScheme(target);
      if (s is VaultSessionStore) {
        s.syncMode(target == 'vault' ? 'os' : 'crypto');
      }
      StreamingStore.syncPasswordState(null);
      if (!mounted) return;
      if (await _promptRestartAfterModeChange() && mounted) {
        await _restartApp();
        return;
      }
      toast(l10n.toastSchemeSwitched, type: ToastType.success);
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
  }

  /// 三档切换条点击分发（v1 系统保护 ↔ v2 口令保护 可逆互切；v3 终点档）：
  ///   v1/v2 → v3：走设备绑定开启（隐私提示 + 可选恢复口令）；
  ///   v3 → v2：走关闭设备绑定（恢复口令授权）；
  ///   v3 → v1：禁止直达（先关闭设备绑定回落 v2）。
  Future<void> _onModeSelected(String target) async {
    final l10n = context.l10n;
    if (_deviceBusy || target == _vaultMode) return;
    // v2 未解锁：回落 v1 / 升级 v3 都需当前口令（档位已灰显，双保险）
    if (_vaultMode == 'password' && !_v2Unlocked) {
      toast(l10n.settingsVaultNeedUnlockFirst, type: ToastType.warning);
      return;
    }
    switch (target) {
      case 'os':
        if (_vaultMode == 'multiseal') {
          toast(l10n.settingsVaultV3NoDirectV1, type: ToastType.warning);
        } else {
          await _switchToOs();
        }
      case 'password':
        if (_vaultMode == 'multiseal') {
          await _disableDeviceBind();
        } else {
          await _switchToPassword();
        }
      case 'multiseal':
        await _enableDeviceBind();
    }
    await _refreshVault();
  }

  /// v1 → v2：确认弹窗 → 设置新口令 → switch-mode password。
  /// 切换后新口令即会话口令（本会话保持解锁，无需重新输入）；
  /// 成功后引导冷切重启（保证数据库完整性与各模块状态一致）。
  Future<void> _switchToPassword() async {
    final l10n = context.l10n;
    final res = await SDialog.show<String>(
      context,
      title: l10n.settingsVaultSwitchToPasswordTitle,
      description: l10n.settingsVaultSwitchToPasswordDesc,
      child: _NewPasswordField(
        newHint: l10n.settingsVaultSwitchToPasswordNewHint,
        confirmHint: l10n.settingsVaultSwitchToPasswordConfirmHint,
        mismatchText: l10n.settingsVaultSwitchToPasswordMismatch,
      ),
    );
    if (res == null || res.isEmpty || !mounted) return;
    final s = getRuntime().sessionStore;
    if (s is! VaultSessionStore) return;
    setState(() => _deviceBusy = true);
    try {
      // 切换前排空持久化队列：避免在途写（携带旧口令/免密约定）落到切换后
      // 的新布局 vault 上失败丢数据（切换后同会话按新模式带口令）。
      await s.flush();
      await StreamingStore.flush();
      await s.switchMode('password', newPassword: res);
      StreamingStore.syncPasswordState(res);
      if (!mounted) return;
      if (await _promptRestartAfterModeChange() && mounted) {
        await _restartApp();
        return;
      }
      toast(l10n.toastVaultSwitchedToPassword, type: ToastType.success);
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
  }

  /// v2 → v1：确认弹窗 → switch-mode os（须本会话已解锁持口令）。
  /// 切换后 OS 份额接管，会话口令清空（免密）；成功后引导冷切重启。
  Future<void> _switchToOs() async {
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.settingsVaultSwitchToOsTitle,
      description: l10n.settingsVaultSwitchToOsDesc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.commonConfirm,
          icon: Icons.check,
          variant: SButtonVariant.primary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok != true || !mounted) return;
    final s = getRuntime().sessionStore;
    if (s is! VaultSessionStore) return;
    setState(() => _deviceBusy = true);
    try {
      // 切换前排空持久化队列（同 _switchToPassword）
      await s.flush();
      await StreamingStore.flush();
      await s.switchMode('os');
      StreamingStore.syncPasswordState(null);
      if (!mounted) return;
      if (await _promptRestartAfterModeChange() && mounted) {
        await _restartApp();
        return;
      }
      toast(l10n.toastVaultSwitchedToOs, type: ToastType.success);
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
  }

  /// 模式切换成功后的冷切引导：明确警告（口令模式重启后需解锁、解锁前
  /// 登录态暂不可用）+ 立即重启 / 稍后重启。返回 true = 立即重启。
  Future<bool> _promptRestartAfterModeChange() async {
    final l10n = context.l10n;
    final res = await SDialog.show<bool>(
      context,
      title: l10n.settingsVaultRestartTitle,
      description: l10n.settingsVaultRestartDesc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.settingsVaultRestartLater,
          variant: SButtonVariant.secondary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsVaultRestartNow,
          icon: Icons.restart_alt,
          variant: SButtonVariant.primary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    return res == true;
  }

  /// 冷切重启：以相同命令行派生新实例（detached）后销毁当前窗口。
  /// 重启后 vault 按新模式初始化，各模块（登录态/流媒体/下载引擎）重新
  /// 以新模式建连，保证数据库完整性。
  Future<void> _restartApp() async {
    try {
      await Process.start(
        Platform.resolvedExecutable,
        Platform.executableArguments,
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      debugPrint('[vault] 重启应用失败（请手动重启）：$e');
    }
    // 退出统一走 exit(0) 链路：绕开 Flutter Linux GTK teardown 崩溃
    // （windowManager.destroy → gtk_window_close → use-after-free 段错误）
    await quitApplication(ref);
  }

  /// 设置/修改恢复口令（须已解锁）：旧口令立即失效。
  Future<void> _changeRecoveryPassword() async {
    final l10n = context.l10n;
    final res = await _promptRecoveryPassword(
      title: l10n.settingsDeviceBindChangeRecoveryTitle,
      description: l10n.settingsDeviceBindChangeRecoveryDesc,
    );
    if (res == null || res.isEmpty || !context.mounted) return;
    setState(() => _deviceBusy = true);
    try {
      await VaultProcess.setRecoveryPassword(resolveDataDir(), res);
      toast(l10n.toastDeviceBindRecoverySet, type: ToastType.success);
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
    }
  }

  /// 重新绑定当前设备（换机口令恢复后调用）：旧指纹立即失效。
  Future<void> _rebindDevice() async {
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.settingsDeviceBindRebindTitle,
      description: l10n.settingsDeviceBindRebindDesc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsDeviceBindRebindConfirm,
          icon: Icons.sync_lock_outlined,
          variant: SButtonVariant.primary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok != true || !context.mounted) return;
    setState(() => _deviceBusy = true);
    try {
      await VaultProcess.rebind(resolveDataDir());
      toast(l10n.toastDeviceBindRebound, type: ToastType.success);
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
    }
  }

  /// 恢复流（设备变更/熵损坏，NEED_RECOVERY）：恢复口令解锁会话+流媒体
  /// 凭据 → 引导重新绑定本机恢复免密。
  Future<void> _recoverVault() async {
    final l10n = context.l10n;
    final res = await _promptRecoveryPassword(
      title: l10n.settingsDeviceBindRecoverTitle,
      description: l10n.settingsDeviceBindRecoverDesc,
    );
    if (res == null || res.isEmpty || !context.mounted) return;
    setState(() => _deviceBusy = true);
    try {
      var ok = false;
      final s = getRuntime().sessionStore;
      if (s is VaultSessionStore) ok = await s.recover(res);
      if (await StreamingStore.recover(res)) ok = true;
      if (!ok) {
        toast(l10n.toastDeviceBindRecoverFailed, type: ToastType.error);
        return;
      }
      if (!mounted) return;
      toast(l10n.toastDeviceBindRecovered, type: ToastType.success);
      // 引导重新绑定本机（恢复免密；跳过则维持口令会话模式）
      final rebind = await SDialog.show<bool>(
        context,
        title: l10n.settingsDeviceBindRebindTitle,
        description: l10n.settingsDeviceBindRebindDesc,
        child: const SizedBox.shrink(),
        actions: [
          SButton(
            label: l10n.commonCancel,
            variant: SButtonVariant.secondary,
            size: SButtonSize.small,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          SButton(
            label: l10n.settingsDeviceBindRebindConfirm,
            icon: Icons.sync_lock_outlined,
            variant: SButtonVariant.primary,
            size: SButtonSize.small,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      );
      if (rebind == true && mounted) await _rebindDevice();
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
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
    final scheme = Theme.of(context).colorScheme;
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
                  '${vaultFilePath()}\n${f(_sessionBytes)} · ${l10n.settingsSecuritySessionDesc}'
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
        _buildDeviceBindSection(l10n, scheme),
      ],
    );
  }

  /// 高级 · 凭据加密方案（Crypto 推荐 / Vault 实验性 二选一；Vault 内含
  /// v1/v2/v3 加密等级 + v3 设备绑定管理）。
  Widget _buildDeviceBindSection(AppLocalizations l10n, ColorScheme scheme) {
    return SettingSection(
      title: l10n.settingsSchemeSection,
      note: l10n.settingsSchemeNote,
      children: [
        // 设备变更/熵损坏：恢复口令解锁入口（红色横幅）
        if (_needsRecovery)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: scheme.error.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline, size: 18, color: scheme.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.settingsDeviceBindRecoveryBanner,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.error,
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SButton(
                    label: l10n.settingsDeviceBindRecover,
                    variant: SButtonVariant.secondary,
                    size: SButtonSize.small,
                    onPressed: _deviceBusy ? null : _recoverVault,
                  ),
                ],
              ),
            ),
          ),
        // 份额不配对（v4 后端指纹不符/份额缺失/GCM 认证失败）：销毁重建引导
        // （红色横幅，区别于可恢复的 _needsRecovery——无口令封装可解）
        if (_shareBroken)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: scheme.error.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.broken_image_outlined,
                      size: 18, color: scheme.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.settingsVaultShareBrokenBanner,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.error,
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SButton(
                    label: l10n.settingsVaultShareBrokenRebuild,
                    variant: SButtonVariant.secondary,
                    size: SButtonSize.small,
                    onPressed: _deviceBusy ? null : _destroyBrokenVault,
                  ),
                ],
              ),
            ),
          ),
        // 加密方案卡片（Crypto 推荐 / Vault 实验性 二选一）
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Row(
            children: [
              Expanded(
                child: _SchemeCard(
                  value: 'crypto',
                  selected: _scheme,
                  busy: _deviceBusy,
                  title: l10n.settingsSchemeCryptoTitle,
                  badge: l10n.settingsSchemeCryptoBadge,
                  badgeColor: scheme.primary,
                  desc: l10n.settingsSchemeCryptoDesc,
                  icon: Icons.vpn_key_outlined,
                  onTap: _onSchemeSelected,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SchemeCard(
                  value: 'vault',
                  selected: _scheme,
                  busy: _deviceBusy,
                  title: l10n.settingsSchemeVaultTitle,
                  badge: l10n.settingsSchemeVaultBadge,
                  badgeColor: scheme.error,
                  desc: l10n.settingsSchemeVaultDesc,
                  icon: Icons.shield_outlined,
                  onTap: _onSchemeSelected,
                ),
              ),
            ],
          ),
        ),
        // 当前方案说明
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _schemeDesc(l10n),
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Vault 方案内含三档加密等级（v1 系统保护 ↔ v2 口令保护 可逆；
        // v3 设备绑定终点档）。Crypto 方案为单因子，无加密等级之分。
        if (_scheme == 'vault') ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ModeCards(
                  values: const ['os', 'password', 'multiseal'],
                  labels: [
                    l10n.settingsVaultModeV1,
                    l10n.settingsVaultModeV2,
                    l10n.settingsVaultModeV3,
                  ],
                  descriptions: [
                    l10n.settingsVaultModeDescOs,
                    l10n.settingsVaultModeDescPassword,
                    l10n.settingsVaultModeDescMultiseal,
                  ],
                  icons: const [
                    Icons.security_outlined,
                    Icons.password_outlined,
                    Icons.devices_outlined,
                  ],
                  selected: _vaultMode,
                  disabledValues: _disabledModes,
                  onChanged: _onModeSelected,
                ),
              ],
            ),
          ),
          // 已开启：恢复口令管理入口
          if (_isDeviceBound) ...[
            SettingTile(
              icon: Icons.password_outlined,
              title: l10n.settingsDeviceBindChangeRecovery,
              subtitle: l10n.settingsDeviceBindChangeRecoveryDesc,
              trailing: IconButton(
                tooltip: l10n.settingsDeviceBindChangeRecovery,
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: _deviceBusy ? null : _changeRecoveryPassword,
                icon: Icon(
                  Icons.chevron_right,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            SettingTile(
              icon: Icons.sync_lock_outlined,
              title: l10n.settingsDeviceBindRebind,
              subtitle: l10n.settingsDeviceBindRebindDesc,
              trailing: IconButton(
                tooltip: l10n.settingsDeviceBindRebind,
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: _deviceBusy ? null : _rebindDevice,
                icon: Icon(
                  Icons.chevron_right,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            SettingTile(
              icon: Icons.link_off_outlined,
              title: l10n.settingsDeviceBindClose,
              subtitle: l10n.settingsDeviceBindCloseDesc,
              trailing: IconButton(
                tooltip: l10n.settingsDeviceBindClose,
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: _deviceBusy ? null : _disableDeviceBind,
                icon: Icon(
                  Icons.chevron_right,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }

  /// 当前加密方案说明（方案卡片下方）：Crypto（单因子稳定）与
  /// Vault（2-of-2 实验性）的总述；未初始化显示读取中。
  String _schemeDesc(AppLocalizations l10n) {
    switch (_scheme) {
      case 'crypto':
        return l10n.settingsSchemeCryptoModeDesc;
      case 'vault':
        return l10n.settingsSchemeVaultModeDesc;
      default:
        return l10n.settingsVaultModeDescUnknown;
    }
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

/// 恢复口令输入区（SDialog child）：口令框（可切换明文）+ 取消/跳过/确认。
/// 经 Navigator.pop 返回值语义（见 [_SecuritySectionState._promptRecoveryPassword]）：
///   null = 取消；'' = 确认但未输入（可选场景=跳过）；其他 = 确认的口令。
class _RecoveryPasswordField extends StatefulWidget {
  const _RecoveryPasswordField({
    required this.hint,
    required this.optional,
    required this.skipLabel,
    required this.confirmLabel,
  });

  final String hint;

  /// 是否允许跳过（可选场景：不设恢复口令直接开启）。
  final bool optional;
  final String skipLabel;
  final String confirmLabel;

  @override
  State<_RecoveryPasswordField> createState() =>
      _RecoveryPasswordFieldState();
}

class _RecoveryPasswordFieldState extends State<_RecoveryPasswordField> {
  final TextEditingController _ctrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _confirm() {
    Navigator.of(context).pop(_ctrl.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: SInput(
                controller: _ctrl,
                autofocus: true,
                obscureText: _obscure,
                hintText: widget.hint,
                prefixIcon: Icons.password_outlined,
                clearable: true,
                textInputAction: TextInputAction.done,
                onSubmitted: widget.optional
                    ? (_) => _confirm()
                    : (_) {
                        if (_ctrl.text.isNotEmpty) _confirm();
                      },
              ),
            ),
            IconButton(
              tooltip: l10n.settingsDeviceBindShowPassword,
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SButton(
              label: l10n.commonCancel,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: () => Navigator.of(context).pop(),
            ),
            if (widget.optional) ...[
              const SizedBox(width: 10),
              SButton(
                label: widget.skipLabel,
                variant: SButtonVariant.ghost,
                size: SButtonSize.small,
                onPressed: () => Navigator.of(context).pop(''),
              ),
            ],
            const SizedBox(width: 10),
            SButton(
              label: widget.confirmLabel,
              icon: Icons.check,
              variant: SButtonVariant.primary,
              size: SButtonSize.small,
              onPressed: widget.optional
                  ? _confirm
                  : (_ctrl.text.isNotEmpty ? _confirm : null),
            ),
          ],
        ),
      ],
    );
  }
}

/// 加密方案选择卡片（Crypto 推荐 / Vault 实验性 二选一）。
/// 选中态描边 + 勾选徽标 + 图标/标题/说明/badge 竖排；
/// [busy] 期间整体禁用防重入。
class _SchemeCard extends StatelessWidget {
  const _SchemeCard({
    required this.value,
    required this.selected,
    required this.busy,
    required this.title,
    required this.badge,
    required this.badgeColor,
    required this.desc,
    required this.icon,
    required this.onTap,
  });

  final String value;
  final String selected;
  final bool busy;
  final String title;
  final String badge;
  final Color badgeColor;
  final String desc;
  final IconData icon;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = value == selected;
    final fg = isSelected ? badgeColor : scheme.onSurface;
    return MouseRegion(
      cursor: busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : () => onTap(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected
                ? badgeColor.withValues(alpha: 0.08)
                : scheme.onSurface.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? badgeColor.withValues(alpha: 0.8)
                  : scheme.outlineVariant.withValues(alpha: 0.5),
              width: isSelected ? 1.6 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                  ),
                  if (isSelected)
                    Icon(Icons.check_circle, size: 16, color: badgeColor),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                desc,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.35,
                  color: busy
                      ? scheme.onSurfaceVariant.withValues(alpha: 0.35)
                      : scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 9.5,
                    color: badgeColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Vault 方案三档加密等级纵向卡片列表（v1 系统保护 / v2 口令保护 / v3
/// 设备绑定）。选中态描边 + 勾选；[disabledValues] 内的档位灰显不可点
/// （busy / v2 未解锁）。
class _ModeCards extends StatelessWidget {
  const _ModeCards({
    required this.values,
    required this.labels,
    required this.descriptions,
    required this.icons,
    required this.selected,
    required this.disabledValues,
    required this.onChanged,
  });

  final List<String> values;
  final List<String> labels;
  final List<String> descriptions;
  final List<IconData> icons;
  final String? selected;
  final Set<String> disabledValues;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (var i = 0; i < values.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i < values.length - 1 ? 8 : 0),
            child: _buildItem(context, scheme, i),
          ),
      ],
    );
  }

  Widget _buildItem(BuildContext context, ColorScheme scheme, int i) {
    final value = values[i];
    final isSelected = value == selected;
    final disabled = disabledValues.contains(value);
    final fg = isSelected ? scheme.primary : scheme.onSurface;
    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: disabled ? null : () => onChanged(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected
                ? scheme.primary.withValues(alpha: 0.08)
                : scheme.onSurface.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? scheme.primary.withValues(alpha: 0.7)
                  : scheme.outlineVariant.withValues(alpha: 0.4),
              width: isSelected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(icons[i], size: 20, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      labels[i],
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: disabled
                            ? fg.withValues(alpha: 0.4)
                            : fg,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      descriptions[i],
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.35,
                        color: disabled
                            ? scheme.onSurfaceVariant.withValues(alpha: 0.3)
                            : scheme.onSurfaceVariant.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isSelected)
                Icon(Icons.check_circle, size: 18, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// 新口令输入区（v1 → v2 切换弹窗 child）：口令 + 确认一致才放行。
/// 经 Navigator.pop 返回确认的新口令（取消返回 null）。
class _NewPasswordField extends StatefulWidget {
  const _NewPasswordField({
    required this.newHint,
    required this.confirmHint,
    required this.mismatchText,
  });

  final String newHint;
  final String confirmHint;
  final String mismatchText;

  @override
  State<_NewPasswordField> createState() => _NewPasswordFieldState();
}

class _NewPasswordFieldState extends State<_NewPasswordField> {
  final TextEditingController _pw = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _pw.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _matched => _pw.text.isNotEmpty && _pw.text == _confirm.text;

  void _submit() {
    if (_matched) Navigator.of(context).pop(_pw.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SInput(
          controller: _pw,
          autofocus: true,
          obscureText: _obscure,
          hintText: widget.newHint,
          prefixIcon: Icons.password_outlined,
          clearable: true,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SInput(
                    controller: _confirm,
                    obscureText: _obscure,
                    hintText: widget.confirmHint,
                    prefixIcon: Icons.verified_outlined,
                    clearable: true,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_confirm.text.isNotEmpty && !_matched)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        widget.mismatchText,
                        style: TextStyle(fontSize: 11, color: scheme.error),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: l10n.settingsDeviceBindShowPassword,
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SButton(
              label: l10n.commonCancel,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 10),
            SButton(
              label: l10n.commonConfirm,
              icon: Icons.check,
              variant: SButtonVariant.primary,
              size: SButtonSize.small,
              onPressed: _matched ? _submit : null,
            ),
          ],
        ),
      ],
    );
  }
}
