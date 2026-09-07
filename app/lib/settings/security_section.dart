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
  bool _deviceBusy = false;

  bool get _hasStreaming => _streamingBytes > 0;
  bool get _hasSession => _sessionBytes > 0 || _neteaseOnline || _kugouOnline;
  bool get _hasUserDb => _userDbBytes > 0;

  bool get _isDeviceBound => _vaultMode == 'multiseal';

  bool get _needsRecovery {
    final s = getRuntime().sessionStore;
    return (s is VaultSessionStore && s.needsRecovery) ||
        StreamingStore.needsRecovery;
  }

  bool get _shareBroken {
    final s = getRuntime().sessionStore;
    return s is VaultSessionStore && s.shareBroken;
  }

  bool get _v2Unlocked {
    final s = getRuntime().sessionStore;
    return s is VaultSessionStore && s.isV2Unlocked;
  }

  Set<String> get _disabledModes {
    if (_deviceBusy) return const {'os', 'password', 'multiseal'};
    if (_vaultMode == 'password' && !_v2Unlocked) {
      return const {'os', 'multiseal'};
    }
    return const {};
  }

  String get _scheme {
    if (_vaultMode == 'crypto' && _vaultBackend == 'file') return 'file';
    if (_vaultMode == 'crypto') return 'crypto';
    if (_vaultMode == 'os' ||
        _vaultMode == 'password' ||
        _vaultMode == 'multiseal') {
      return 'vault';
    }
    return ref.read(appPrefsProvider).credentialScheme;
  }

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
    try {
      mode = await VaultProcess.mode(resolveDataDir());
      backend = await VaultProcess.backend(resolveDataDir());
    } catch (_) {}
    if (!mounted || (mode == _vaultMode && backend == _vaultBackend)) return;
    setState(() {
      _vaultMode = mode;
      _vaultBackend = backend;
    });
  }

  @override
  Widget build(BuildContext context) => _buildSecuritySection(context);
}
