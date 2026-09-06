// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../kugou_login_button.dart';

extension _KugouLoginButtonView on _KugouLoginButtonState {
  Widget _buildKugouLoginButton(BuildContext context) {
    final api = _api;
    return ListenableBuilder(
      listenable: api,
      builder: (context, _) {
        final theme = Theme.of(context);
        final l10n = context.l10n;
        final session = api.session;
        final nickname = session?.nickname;
        return PopupMenuButton<String>(
          tooltip: session == null
              ? l10n.loginKugouQrLogin(l10n.brandKugou)
              : l10n.loginKugouSession(l10n.brandKugou),
          // 性能模式：菜单直出，无淡入/弹出动效
          popUpAnimationStyle: noAnim(context)
              ? AnimationStyle.noAnimation
              : null,
          onSelected: (v) {
            if (v == 'login') _openLogin();
            if (v == 'logout') _logout();
          },
          itemBuilder: (context) => session == null
              ? [PopupMenuItem(value: 'login', child: Text(l10n.loginQrLogin))]
              : [
                  PopupMenuItem(
                    value: 'logout',
                    child: Text(
                      l10n.loginLogoutWithId(nickname ?? session.userid),
                    ),
                  ),
                ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  session == null ? Icons.person_outline : Icons.person,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  session == null
                      ? l10n.loginKugouLogin(l10n.brandKugou)
                      : (nickname ?? l10n.loginKugouLoggedIn(l10n.brandKugou)),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

extension _KgQrLoginDialogView on _KgQrLoginDialogState {
  Widget _buildKgQrLoginDialog(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    // 全屏毛玻璃背景 + 居中实体化二维码卡片（白底 + 阴影悬浮）：
    // 标题在卡片上方、状态在下方，点击卡片以外任意处直接关闭（无关闭键）。
    // 毛玻璃直接自建 BackdropFilter（不依赖 GlassDialogSurface——它仅在
    // 图片风格下 blur，且传不透明色时 blur 会被完全盖住，两风格都显示为
    // 实底面板，看不到毛玻璃效果）。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(false),
      child: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: ColoredBox(
            // 半透明面板色：主界面内容透过模糊可见，毛玻璃质感
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.8),
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  // 卡片区域（含上下文字）消费点击，避免误触外层关闭
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: SizedBox(
                      width: 320,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.loginKugouQrLogin(l10n.brandKugou),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 20),
                          // 实体化卡片：白底圆角 + 阴影悬浮，二维码需浅色底
                          Container(
                            width: 300,
                            height: 300,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.25),
                                  blurRadius: 24,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                            child: Center(
                              child: _loadingKey
                                  ? const SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                      ),
                                    )
                                  : _key != null
                                  ? QrImageView(
                                      data: '$kgQrLoginPage?qrcode=$_key',
                                      version: QrVersions.auto,
                                      size: 260,
                                    )
                                  : _buildQrError(scheme, l10n),
                            ),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            height: 24,
                            child: Center(
                              child: Text(
                                _statusText(l10n),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 错误状态（实体卡片内部）：图标 + 限行文本 + 重新生成按钮。
  Widget _buildQrError(ColorScheme scheme, AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline, size: 48, color: scheme.error),
        const SizedBox(height: 12),
        Text(
          _error,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black87, fontSize: 13),
          // 网络异常消息可能很长（含 URL/堆栈），限 4 行截断保持版面紧凑
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 16),
        FilledButton.tonalIcon(
          onPressed: _initQr,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.loginRegenerate),
        ),
      ],
    );
  }
}
