// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../nav_header.dart';

class _AccountsMenu extends ConsumerWidget {
  const _AccountsMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final netease = ref.watch(neteaseAuthProvider);
    final kugouApi = ref.read(kugouApiProvider);
    final qqApi = ref.read(qqMusicApiProvider);

    return ListenableBuilder(
      listenable: Listenable.merge([kugouApi, qqApi]),
      builder: (context, _) {
        final kugou = kugouApi.session;
        final qqProfile = qqApi.profile;
        final qqLogged = qqApi.isLoggedIn;

        final primaryNetease = netease != null;
        final primaryKugou = !primaryNetease && kugou != null;
        final primaryQq = !primaryNetease && !primaryKugou && qqLogged;
        final anyLoggedIn = primaryNetease || primaryKugou || primaryQq;

        final avatarUrl = netease?.avatarUrl?.trim();
        final neteaseNick = netease?.nickname.trim() ?? '';
        final kugouNick = kugou?.nickname?.trim() ?? '';
        final qqNick = qqProfile?.nickname.trim() ?? '';

        Widget primary;
        if (primaryNetease) {
          primary = _AccountAvatar(avatarUrl: avatarUrl, nickname: neteaseNick);
        } else if (primaryKugou) {
          primary = _AccountAvatar(
            avatarUrl: kugou.avatarUrl,
            nickname: kugouNick.isEmpty ? kugou.userid : kugouNick,
          );
        } else if (primaryQq) {
          primary = _AccountAvatar(
            avatarUrl: qqProfile?.avatarUrl,
            nickname: qqNick.isEmpty ? qqApi.uin : qqNick,
          );
        } else {
          primary = Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.person_outline,
              size: 19,
              color: colorScheme.primary,
            ),
          );
        }

        return PopupMenuButton<String>(
          tooltip: anyLoggedIn
              ? l10n.navHeaderAccount
              : l10n.navHeaderLoginAccount,
          position: PopupMenuPosition.under,
          offset: const Offset(0, 6),
          popUpAnimationStyle: noAnim(context)
              ? AnimationStyle.noAnimation
              : null,
          onSelected: (key) async {
            switch (key) {
              case 'login_netease':
                showNeteaseLoginDialog(context);
              case 'logout_netease':
                await ref.read(neteaseAuthProvider.notifier).logout();
              case 'login_kugou':
                showDialog<bool>(
                  context: context,
                  barrierColor: Colors.black.withValues(alpha: 0.5),
                  barrierDismissible: false,
                  builder: (_) => const KgQrLoginDialog(),
                );
              case 'logout_kugou':
                ref.read(kugouApiProvider).clearSession();
              case 'login_qq':
                showQqMusicLoginDialog(context);
              case 'logout_qq':
                ref.read(qqMusicApiProvider).logout();
                toast(context.l10n.loginLoggedOut(context.l10n.brandQqMusic));
            }
          },
          itemBuilder: (_) => [
            ..._platformSection(
              l10n: l10n,
              title: l10n.navHeaderNeteaseMusic,
              loggedIn: netease != null,
              loginValue: 'login_netease',
              logoutValue: 'logout_netease',
              nameValue: 'name_netease',
              avatarUrl: avatarUrl,
              avatarName: neteaseNick,
              displayName: neteaseNick.isEmpty
                  ? l10n.navHeaderNeteaseAccount
                  : neteaseNick,
            ),
            ..._platformSection(
              l10n: l10n,
              title: l10n.navHeaderKugouMusic,
              loggedIn: kugou != null,
              loginValue: 'login_kugou',
              logoutValue: 'logout_kugou',
              nameValue: 'name_kugou',
              avatarUrl: kugou?.avatarUrl,
              avatarName: kugouNick.isEmpty ? (kugou?.userid ?? '') : kugouNick,
              displayName: kugouNick.isEmpty
                  ? l10n.navHeaderKugouId(kugou?.userid ?? '')
                  : kugouNick,
            ),
            ..._platformSection(
              l10n: l10n,
              title: l10n.navHeaderQqMusic,
              loggedIn: qqLogged,
              loginValue: 'login_qq',
              logoutValue: 'logout_qq',
              nameValue: 'name_qq',
              avatarUrl: qqProfile?.avatarUrl,
              avatarName: qqNick.isEmpty ? qqApi.uin : qqNick,
              displayName: qqNick.isEmpty
                  ? l10n.navHeaderQqId(qqApi.uin)
                  : qqNick,
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                primary,
                if (anyLoggedIn) ...[
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 100),
                    child: Text(
                      primaryNetease
                          ? neteaseNick
                          : primaryKugou
                          ? (kugouNick.isEmpty ? l10n.brandKugou : kugouNick)
                          : (qqNick.isEmpty ? l10n.brandQqMusic : qqNick),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  List<PopupMenuEntry<String>> _platformSection({
    required AppLocalizations l10n,
    required String title,
    required bool loggedIn,
    required String loginValue,
    required String logoutValue,
    required String nameValue,
    String? avatarUrl,
    required String avatarName,
    required String displayName,
  }) {
    return [
      _MenuSectionLabel(title),
      if (!loggedIn)
        PopupMenuItem(
          value: loginValue,
          height: 36,
          child: Row(
            children: [
              const Icon(Icons.qr_code_2, size: 17),
              const SizedBox(width: 10),
              Text(l10n.navHeaderQrLogin),
            ],
          ),
        )
      else ...[
        PopupMenuItem(
          value: nameValue,
          enabled: false,
          height: 44,
          child: Row(
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: _AccountAvatar(
                  avatarUrl: avatarUrl,
                  nickname: avatarName,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: logoutValue,
          height: 36,
          child: Row(
            children: [
              const Icon(Icons.logout, size: 17),
              const SizedBox(width: 10),
              Text(l10n.navHeaderLogout),
            ],
          ),
        ),
      ],
      const PopupMenuDivider(height: 4),
    ];
  }
}

class _MenuSectionLabel extends PopupMenuEntry<String> {
  const _MenuSectionLabel(this.text);

  final String text;

  @override
  double get height => 30;

  @override
  bool represents(String? value) => false;

  @override
  State<_MenuSectionLabel> createState() => _MenuSectionLabelState();
}

class _MenuSectionLabelState extends State<_MenuSectionLabel> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        widget.text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({this.avatarUrl, required this.nickname});

  final String? avatarUrl;
  final String nickname;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final url = avatarUrl?.trim();
    if (url != null && url.isNotEmpty) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final avatarPx = (34 * dpr).round();
      return ClipOval(
        child: Image.network(
          url,
          width: 34,
          height: 34,
          fit: BoxFit.cover,
          cacheWidth: avatarPx,
          cacheHeight: avatarPx,
          errorBuilder: (_, _, _) => _fallback(colorScheme),
        ),
      );
    }
    return _fallback(colorScheme);
  }

  Widget _fallback(ColorScheme colorScheme) {
    final letter = nickname.isNotEmpty ? nickname.characters.first : '?';
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: colorScheme.primary,
        ),
      ),
    );
  }
}
