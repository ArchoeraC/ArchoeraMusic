// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../nav_header.dart';

class _NavHeaderSearchField extends StatelessWidget {
  const _NavHeaderSearchField({
    required this.layerLink,
    required this.widthAnimation,
    required this.width,
    required this.searchFocus,
    required this.searchCtrl,
    required this.hintText,
    required this.onChanged,
    required this.onSubmitted,
  });

  final LayerLink layerLink;
  final Animation<double> widthAnimation;
  final double width;
  final FocusNode searchFocus;
  final TextEditingController searchCtrl;
  final String hintText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          searchFocus.unfocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: CompositedTransformTarget(
        link: layerLink,
        child: AnimatedBuilder(
          animation: widthAnimation,
          builder: (_, child) => SizedBox(width: width, child: child),
          child: SInput(
            controller: searchCtrl,
            focusNode: searchFocus,
            hintText: hintText,
            prefixIcon: EtaIcons.search2,
            clearable: true,
            textInputAction: TextInputAction.search,
            onChanged: onChanged,
            onSubmitted: onSubmitted,
          ),
        ),
      ),
    );
  }
}

class _NavHeaderActionsMenu extends ConsumerWidget {
  const _NavHeaderActionsMenu();

  IconData _themeIcon(ThemeMode mode) => switch (mode) {
    ThemeMode.light => EtaIcons.sunOutline,
    ThemeMode.dark => EtaIcons.moonOutline,
    ThemeMode.system => EtaIcons.brightnessOutline,
  };

  String _themeLabel(AppLocalizations l10n, ThemeMode mode) => switch (mode) {
    ThemeMode.light => l10n.navHeaderThemeLight,
    ThemeMode.dark => l10n.navHeaderThemeDark,
    ThemeMode.system => l10n.navHeaderThemeSystem,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final mode = ref.watch(themeModeProvider);
    return PopupMenuButton<String>(
      tooltip: l10n.commonMore,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      popUpAnimationStyle: noAnim(context) ? AnimationStyle.noAnimation : null,
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
              Icon(_themeIcon(mode), size: 17),
              const SizedBox(width: 10),
              Text(_themeLabel(l10n, mode)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'settings',
          height: 40,
          child: Row(
            children: [
              const Icon(EtaIcons.settingsOutline, size: 17),
              const SizedBox(width: 10),
              Text(l10n.commonSettings),
            ],
          ),
        ),
      ],
      child: const SizedBox(
        width: 40,
        height: 40,
        child: Center(child: Icon(EtaIcons.dotsVertical, size: 20)),
      ),
    );
  }
}
