// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 安装向导的草稿状态：把各步骤收集到的选择攒成一个可提交的 [LivePlan]。
///
/// 放在独立文件里是为了让「收集」与「渲染」分离，并让校验规则可单测
/// （[passphraseError] / [nameError] / [canStart]）。
library;

import '../services/platform/live_install.dart';
import 'installer_options.dart';

/// 向导步骤（顺序即导航顺序）。
enum InstallerStep {
  language,
  timezone,
  keyboard,
  disk,
  encryption,
  user,
  summary,
  progress,
  done,
}

/// 安装草稿。
class InstallerDraft {
  InstallerDraft({InstallerLanguage? language, this.timezone = 'UTC'})
    : language =
          language ?? installerLanguages[installerLanguages.length > 1 ? 1 : 0];

  /// 语言（同时决定系统 locale 与向导界面语言）。
  InstallerLanguage language;

  /// 时区（zoneinfo 名）。
  String timezone;

  /// 控制台键盘布局。
  String keymap = 'us';

  /// 目标磁盘设备路径（如 `/dev/nvme0n1`）；未选为 null。
  String? disk;

  /// 根文件系统（`ext4` / `btrfs`）。
  String fs = 'ext4';

  /// 交换（`none` / `file`）。
  String swap = 'none';

  /// 是否用 LUKS2 加密 root。
  bool encrypt = false;

  String luksPassphrase = '';
  String luksConfirm = '';

  String hostname = 'archoera';
  String username = 'archoera';
  String userPassword = '';
  String rootPassword = '';

  /// 是否保持 tty1 自动登录进 kiosk。
  bool autologin = true;

  /// btrfs 上安装器不支持交换文件，这里直接收敛，避免提交必失败的组合。
  void normalize() {
    if (fs == 'btrfs' && swap == 'file') swap = 'none';
    if (!encrypt) {
      luksPassphrase = '';
      luksConfirm = '';
    }
  }

  /// 加密口令校验（返回 null 表示通过）。
  String? passphraseError({
    required String tooShort,
    required String mismatch,
    int minLength = 8,
  }) {
    if (!encrypt) return null;
    if (luksPassphrase.length < minLength) return tooShort;
    if (luksPassphrase != luksConfirm) return mismatch;
    return null;
  }

  /// 主机名 / 用户名校验（返回 null 表示通过）。
  String? nameError(String value, {required String invalid}) =>
      isValidName(value) ? null : invalid;

  /// 摘要步骤是否可提交。
  bool get canStart =>
      disk != null && isValidName(hostname) && isValidName(username);

  /// 生成安装计划（[normalize] 后调用）。
  LivePlan toPlan() {
    normalize();
    return LivePlan(
      disk: disk ?? '',
      hostname: hostname.trim(),
      username: username.trim(),
      locale: language.locale,
      timezone: timezone,
      keymap: keymap,
      fs: fs,
      swap: swap,
      encrypt: encrypt,
      autologin: autologin,
      luksPassphrase: luksPassphrase,
      userPassword: userPassword,
      rootPassword: rootPassword,
    );
  }
}
