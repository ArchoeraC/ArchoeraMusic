import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme_provider.dart';
import '../../settings/settings_dialog.dart';
import '../../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../dialogs/kugou_login_button.dart';
import '../dialogs/netease_login_dialog.dart';
import '../player/s_controls.dart';
import '../common/anim.dart';

/// 顶部导航栏（对齐原项目 NavHeader.vue）。
///
/// 布局：返回 / 全局搜索框（SInput，回车跳搜索页）/（弹性留白）/ 用户 /
/// 齿轮下拉（主题循环 light→dark→system + 全局设置占位）。
/// 窗口控制（最小化/关闭）由 Linux 系统窗口管理，桌面壳不绘制
/// （原项目 WindowControls 仅在无边框窗口启用）。
class NavHeader extends ConsumerStatefulWidget {
  const NavHeader({super.key});

  @override
  ConsumerState<NavHeader> createState() => _NavHeaderState();
}

class _NavHeaderState extends ConsumerState<NavHeader> {
  late final TextEditingController _searchCtrl;
  final _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _submitSearch(String q) {
    final query = q.trim();
    if (query.isEmpty) return;
    context.go('/search?q=${Uri.encodeQueryComponent(query)}');
    _searchFocus.unfocus();
  }

  /// 主题循环按钮图标（展示当前模式）。
  IconData get _themeIcon => switch (ref.watch(themeModeProvider)) {
        ThemeMode.light => Icons.light_mode_outlined,
        ThemeMode.dark => Icons.dark_mode_outlined,
        ThemeMode.system => Icons.brightness_auto_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            // 返回（对齐 NavHeader 的 chevron-left 圆角按钮）
            IconButton(
              tooltip: l10n.commonBack,
              onPressed: context.canPop() ? () => context.pop() : null,
              icon: const Icon(Icons.chevron_left, size: 22),
            ),
            const SizedBox(width: 8),
            // 全局搜索框（对齐 NavSearch.vue，回车跳转搜索页）
            SInput(
              width: 280,
              controller: _searchCtrl,
              focusNode: _searchFocus,
              hintText: l10n.navHeaderSearchHint,
              prefixIcon: Icons.search,
              clearable: true,
              textInputAction: TextInputAction.search,
              onSubmitted: _submitSearch,
            ),
            const Spacer(),
            // 账号（多平台：网易云 / 酷狗 / QQ 音乐占位）
            const _AccountsMenu(),
            const SizedBox(width: 4),
            // 齿轮下拉（对齐 NavHeader SDropdownMenu：主题 + 全局设置）
            PopupMenuButton<String>(
              tooltip: l10n.commonMore,
              position: PopupMenuPosition.under,
              offset: const Offset(0, 6),
              // 性能模式：菜单直出，无淡入/弹出动效
              popUpAnimationStyle: noAnim(context)
                  ? AnimationStyle.noAnimation
                  : null,
              onSelected: (key) {
                if (key == 'theme') {
                  ref.read(themeModeProvider.notifier).cycle();
                } else if (key == 'settings') {
                  showSettingsDialog(context);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'theme',
                  height: 40,
                  child: Row(
                    children: [
                      Icon(_themeIcon, size: 17),
                      const SizedBox(width: 10),
                      Text(
                        switch (ref.watch(themeModeProvider)) {
                          ThemeMode.light => l10n.navHeaderThemeLight,
                          ThemeMode.dark => l10n.navHeaderThemeDark,
                          ThemeMode.system => l10n.navHeaderThemeSystem,
                        },
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'settings',
                  height: 40,
                  child: Row(
                    children: [
                      const Icon(Icons.settings_outlined, size: 17),
                      const SizedBox(width: 10),
                      Text(l10n.commonSettings),
                    ],
                  ),
                ),
              ],
              child: const SizedBox(
                width: 40,
                height: 40,
                child: Center(child: Icon(Icons.more_vert, size: 20)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 账号入口（多平台）：未登录显示登录入口，已登录显示主账号（优先网易云
/// 头像）。菜单列出各平台登录态：网易云 / 酷狗（均支持扫码登录），
/// QQ 音乐暂不可用（原版 SPlayer-Next 无登录；Mineradio 走祈水第三方
/// 授权平台，Flutter 桌面不移植）。
class _AccountsMenu extends ConsumerWidget {
  const _AccountsMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final netease = ref.watch(neteaseAuthProvider);
    final kugouApi = ref.read(kugouApiProvider);

    return ListenableBuilder(
      listenable: kugouApi,
      builder: (context, _) {
        final kugou = kugouApi.session;

        // 主账号：网易云 > 酷狗
        final primaryNetease = netease != null;
        final primaryKugou = !primaryNetease && kugou != null;
        final anyLoggedIn = primaryNetease || primaryKugou;

        final avatarUrl = netease?.avatarUrl?.trim();
        final neteaseNick = netease?.nickname.trim() ?? '';
        final kugouNick = kugou?.nickname?.trim() ?? '';

        Widget primary;
        if (primaryNetease) {
          primary = _AccountAvatar(
            avatarUrl: avatarUrl,
            nickname: neteaseNick,
          );
        } else if (primaryKugou) {
          primary = _AccountAvatar(
            avatarUrl: kugou.avatarUrl,
            nickname: kugouNick.isEmpty ? kugou.userid : kugouNick,
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
          // 性能模式：菜单直出，无淡入/弹出动效
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
            }
          },
          itemBuilder: (_) => [
            // ── 网易云 / 酷狗（同构：标题 + 登录入口 或 头像+昵称+退出）──
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
            // ── QQ 音乐（占位） ────────────────────────────────
            _MenuSectionLabel(l10n.navHeaderQqMusic),
            PopupMenuItem(
              value: 'qq_soon',
              enabled: false,
              height: 36,
              child: Row(
                children: [
                  const Icon(Icons.hourglass_empty, size: 17),
                  const SizedBox(width: 10),
                  Text(l10n.navHeaderComingSoon),
                ],
              ),
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
                          : (kugouNick.isEmpty ? l10n.brandKugou : kugouNick),
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

  /// 单个平台账号区段：标题 + 未登录「扫码登录」入口，或已登录的
  /// 「头像 + 昵称」与退出项（网易云 / 酷狗同构复用）。
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

/// 菜单区段标题（不可选中，仅展示平台名）。
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

/// 账号头像（网络图失败回退昵称首字）。
class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({this.avatarUrl, required this.nickname});

  final String? avatarUrl;
  final String nickname;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final url = avatarUrl?.trim();
    if (url != null && url.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          url,
          width: 34,
          height: 34,
          fit: BoxFit.cover,
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
