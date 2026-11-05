// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 提权启动防呆门（root / 管理员）。
///
/// 音频播放、下载与凭据保险库都不需要超级用户权限：以 root / 管理员身份运行只会
/// 让整台机器暴露在应用的任何缺陷（RCE、供应链投毒）之下，并把偏好 / 缓存 / 日志
/// 写成普通用户难以读取或清理的属主。故启动时先探测提权，命中则**只**渲染本门：
/// 单实例仲裁、凭据保险库、SQLite 预加载、托盘与主界面全部延后，直到用户显式
/// 选择「退出」或「仍要继续」。
///
/// 默认焦点在「退出」；检测失败（桥接不可用 / 后端错误）按未提权处理，不让防呆
/// 机制本身变成新的启动故障源。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/platform/process_elevation.dart';
import '../theme/app_theme.dart';

/// 提权启动的唯一 UI：返回 true 才允许继续正常启动，false 表示调用方应退出。
Future<bool> runElevationGate(
  ProcessElevation elevation, {
  required Locale locale,
}) {
  final decision = Completer<bool>();
  runApp(
    _ElevationGateApp(
      elevation: elevation,
      locale: locale,
      onDecision: (proceed) {
        if (!decision.isCompleted) decision.complete(proceed);
      },
    ),
  );
  return decision.future;
}

class _ElevationGateApp extends StatelessWidget {
  const _ElevationGateApp({
    required this.elevation,
    required this.locale,
    required this.onDecision,
  });

  final ProcessElevation elevation;
  final Locale locale;
  final ValueChanged<bool> onDecision;

  @override
  Widget build(BuildContext context) {
    // 固定暗色：sudo 常在暗色终端后立刻出现，白屏首帧等同闪光弹。
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appName,
      theme: buildAppTheme(AppPalette.dark, Brightness.dark),
      darkTheme: buildAppTheme(AppPalette.dark, Brightness.dark),
      themeMode: ThemeMode.dark,
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      debugShowCheckedModeBanner: false,
      home: ElevationGatePage(elevation: elevation, onDecision: onDecision),
    );
  }
}

/// 防呆门页面（独立出来供 widget 测试驱动两个决策）。
class ElevationGatePage extends StatelessWidget {
  const ElevationGatePage({
    super.key,
    required this.elevation,
    required this.onDecision,
  });

  final ProcessElevation elevation;
  final ValueChanged<bool> onDecision;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final kind = elevation.kind == ProcessElevationKind.administrator
        ? l10n.elevationGateKindAdministrator
        : l10n.elevationGateKindRoot;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 40,
                        color: scheme.error,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            l10n.elevationGateTitle,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.elevationGateBody(kind: kind),
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        key: const ValueKey('elevation-gate-exit'),
                        // 默认焦点放在安全选项：误按 Enter 只会退出，不会提权继续。
                        autofocus: true,
                        onPressed: () => onDecision(false),
                        child: Text(l10n.elevationGateExit),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        key: const ValueKey('elevation-gate-continue'),
                        style: FilledButton.styleFrom(
                          backgroundColor: scheme.error,
                          foregroundColor: scheme.onError,
                        ),
                        onPressed: () => onDecision(true),
                        child: Text(l10n.elevationGateContinue),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
