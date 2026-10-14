// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 存储分类下的「安全销毁」危险区（敏感数据不可逆擦除）。
///
/// 对齐需求：必要情况下允许用户直接销毁敏感数据库 —
/// 主动失效 token（NT /api/logout）+ 随机数据覆盖写入并删除文件。
///
/// 覆盖清单（本项目实际含凭据的本地文件）：
/// - 流媒体服务器凭据 [streamingServersPath]
/// - 第三方账号会话 [sessionStorePath]
/// - 本地用户库 [userDbPath]
///
/// 所有销毁均要求输入确认词（settingsSecurityConfirmWord）二次确认；
/// 曲库 library.db / 历史 history.db / 下载文件不在销毁范围。
library;

import 'dart:io';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apis/netease/api.dart' show nmClearNeteaseCookies;
import '../../apis/runtime.dart' show getRuntime;
import '../../app/app_quit.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/log/log.dart';
import '../../services/mcp/mcp_key_store.dart';
import '../../services/security/data_destroyer.dart';
import '../../services/security/vault_kdf.dart';
import '../../services/security/vault_process.dart';
import '../../services/streaming/streaming_provider.dart';
import '../../services/streaming/streaming_store.dart';
import '../../stores/app_prefs.dart';
import '../../stores/data_dir.dart';
import '../../stores/providers.dart';
import '../../stores/vault_session_store.dart';
import '../../stores/vault_unlock_refresh.dart';
import '../../widgets/common/toast.dart';
import '../../widgets/dialogs/s_dialog.dart';
import '../../widgets/player/s_controls.dart';
import 'security/vault_scheme_slider.dart';
import '../services/security/vault_switch_snapshot.dart';
import 'settings_widgets.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'security/security_section_actions.dart';
part 'security/security_section_view.dart';
part 'security/security_section_widgets.dart';

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

  String? _vaultMode;
  String? _vaultBackend;

  /// vault 实际口令槽 KDF 强度（status；仅 m1/m2a 非空）——用于回显真实
  /// 生效值（与偏好可能因外部改动而不一致）。
  ({int m, int t, int p})? _vaultKdf;
  bool _deviceBusy = false;

  bool get _hasStreaming => _streamingBytes > 0;
  bool get _hasSession => _sessionBytes > 0 || _neteaseOnline || _kugouOnline;
  bool get _hasUserDb => _userDbBytes > 0;

  bool get _needsRecovery {
    final s = getRuntime().sessionStore;
    return (s is VaultSessionStore && s.needsRecovery) ||
        StreamingStore.needsRecovery;
  }

  /// 本会话凭据库尚未解锁（m1/m2a）→ 设置页提供**补解锁**入口。
  ///
  /// 为什么必须有：解锁门可被「暂不解锁」跳过，而解锁动作此前只在门里调用过 →
  /// 跳过之后本会话再无入口解锁，登录态读不回来只能重启（2026-10-14 实录）。
  bool get _needsUnlock {
    final s = getRuntime().sessionStore;
    return (s is VaultSessionStore && s.needsPassword) ||
        StreamingStore.needsPassword;
  }

  bool get _shareBroken {
    final s = getRuntime().sessionStore;
    return s is VaultSessionStore && s.shareBroken;
  }

  /// Vault 变体滑条的**拖动预览**档位（null = 未拖动，回显当前生效档位）。
  /// 松手才会经 [_onSchemeSelected] 提交切换。
  int? _vaultSliderPending;

  /// 更新滑条拖动预览档位（view 扩展经此调用——扩展不能直接用 `setState`，属 protected 成员）。
  void _setVaultSliderPending(int? index) =>
      setState(() => _vaultSliderPending = index);

  /// 当前生效方案（crypto/file/m1/m2a/m2b）。
  /// 已初始化的库按 status 返回的 mode/backend 判定（真实生效值）；
  /// 未初始化（mode=null，如全新数据目录）由 prefs 偏好兜底（默认 crypto）。
  String get _scheme {
    switch (_vaultMode) {
      case 'm1':
        return 'm1';
      case 'm2a':
        return 'm2a';
      case 'm2b':
        return 'm2b';
      case 'crypto':
        return _vaultBackend == 'file' ? 'file' : 'crypto';
    }
    final pref = ref.read(appPrefsProvider).credentialScheme;
    return switch (pref) {
      'file' => 'file',
      'm1' => 'm1',
      'm2a' => 'm2a',
      'm2b' => 'm2b',
      _ => 'crypto',
    };
  }

  /// m2a 且用户尚未确认已备份恢复码 → 设置区显示持久提醒。
  bool get _m2aRecoveryReminder =>
      _scheme == 'm2a' && !ref.read(appPrefsProvider).m2aRecoveryAcked;

  Future<void> _onSchemeSelected(String target) async {
    if (_deviceBusy || target == _scheme) return;
    await _switchScheme(target);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

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

  Future<void> _refreshVault() async {
    String? mode;
    String? backend;
    ({int m, int t, int p})? kdf;
    try {
      final dir = resolveDataDir();
      mode = await VaultProcess.mode(dir);
      backend = await VaultProcess.backend(dir);
      kdf = await VaultProcess.kdf(dir);
    } catch (_) {}
    if (!mounted ||
        (mode == _vaultMode && backend == _vaultBackend && kdf == _vaultKdf)) {
      return;
    }
    setState(() {
      _vaultMode = mode;
      _vaultBackend = backend;
      _vaultKdf = kdf;
    });
  }

  /// 实际 KDF 参数 → 预设 id（匹配不上返回 null，回退偏好回显）。
  String? _presetIdForKdf(({int m, int t, int p})? kdf) {
    if (kdf == null) return null;
    for (final p in vaultKdfPresets) {
      if (p.mKiB == kdf.m && p.t == kdf.t && p.p == kdf.p) return p.id;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => _buildSecuritySection(context);
}
