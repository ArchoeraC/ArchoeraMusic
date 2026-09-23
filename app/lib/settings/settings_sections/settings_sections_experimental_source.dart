// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 实验性音源（第三方音源，默认关闭）────────────────────────────────

/// 实验性音源分类：总开关 + 登录/退出。
///
/// 当前仅接入 NekoMusic（标识 `neko`，显示名 NK）：统一 REST + token 的
/// 第三方音源。**默认关闭**；关闭时不参与搜索 / 我喜欢 / 收藏，也不发请求。
/// 仅提供登录（账号密码 + 二维码），不含注册与 VIP 购买。
///
/// 服务器地址固定（不对外暴露为可设置项）。
class ExperimentalSourceSection extends ConsumerStatefulWidget {
  const ExperimentalSourceSection({super.key});

  @override
  ConsumerState<ExperimentalSourceSection> createState() =>
      _ExperimentalSourceSectionState();
}

class _ExperimentalSourceSectionState
    extends ConsumerState<ExperimentalSourceSection> {
  void _toggleNeko(bool value) {
    ref.read(appPrefsProvider.notifier).setNekoEnabled(value);
    toast(
      value
          ? context.l10n.settingsNekoEnable
          : context.l10n.settingsExperimentalSourceSubtitle,
      type: value ? ToastType.success : ToastType.info,
    );
    setState(() {});
  }

  Future<void> _login() async {
    await showNekoLoginDialog(context);
    if (mounted) setState(() {});
  }

  void _logout() {
    ref.read(nekoApiProvider).logout();
    ref.read(likeControllerProvider).sync();
    setState(() {});
    toast(context.l10n.settingsNekoLogout, type: ToastType.info);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = ref.watch(appPrefsProvider.select((p) => p.nekoEnabled));
    // 登录态变化时重建（账号名 / 登录按钮）。
    final neko = ref.watch(nekoApiProvider);
    final account = neko.account;
    final loggedIn = neko.isLoggedIn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsNekoTitle,
          note: l10n.settingsNekoNote,
          children: [
            SettingTile(
              icon: EtaIcons.flaskOutline,
              title: l10n.settingsNekoEnable,
              subtitle: l10n.settingsNekoEnableDesc,
              trailing: Switch(value: enabled, onChanged: _toggleNeko),
            ),
            SettingTile(
              icon: EtaIcons.userOutline,
              title: l10n.settingsNekoLogin,
              subtitle: loggedIn
                  ? l10n.settingsNekoLoggedInAs(name: account?.displayName ?? '')
                  : l10n.settingsNekoNotLoggedIn,
              enabled: enabled,
              trailing: loggedIn
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _NekoAvatar(
                          url: neko.userAvatarUrl(account?.id),
                          name: account?.displayName ?? '',
                        ),
                        const SizedBox(width: 10),
                        SButton(
                          label: l10n.settingsNekoLogout,
                          variant: SButtonVariant.secondary,
                          onPressed: _logout,
                        ),
                      ],
                    )
                  : SButton(
                      label: l10n.settingsNekoLogin,
                      onPressed: enabled ? _login : null,
                    ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Neko 登录用户头像（`GET /api/user/avatar/{userId}`）；无 URL 时回退首字母占位。
class _NekoAvatar extends StatelessWidget {
  const _NekoAvatar({required this.url, required this.name});

  final String? url;
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const double size = 28;
    final placeholder = CircleAvatar(
      radius: size / 2,
      backgroundColor: scheme.primaryContainer,
      child: Text(
        name.isNotEmpty ? name.characters.first : '?',
        style: TextStyle(
          fontSize: 12,
          color: scheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    final u = url;
    if (u == null || u.isEmpty) return placeholder;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final px = (size * dpr).round();
    return ClipOval(
      child: Image.network(
        u,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: px,
        cacheHeight: px,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}
