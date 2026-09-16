// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_dialog.dart';

/// 开发者模式长按反馈门槛：前这么久不显示进度条（防误触）。
const Duration _kDevHoldGate = Duration(milliseconds: 1500);

/// 开发者模式长按总时长（从按下即开始计时）。
const Duration _kDevHoldDuration = Duration(seconds: 10);

extension _SettingsDialogActions on _SettingsDialogState {
  Future<void> _loadVersion() async {
    try {
      final data = await rootBundle.loadString('pubspec.yaml');
      final match = RegExp(
        r'^version:\s*([0-9][^\s#]*)(?:\s*#.*)?$',
        multiLine: true,
      ).firstMatch(data);
      var v = match?.group(1) ?? '';
      // Dart 版本号中 '-' 预发布、'+' 构建号 → 显示时转回 '.' 分段；
      // 构建号 'rev.N' 归一为 'revN'（如 0.9.11+rev.4 → 0.9.11.rev4），
      // 纯数字/其它构建号仍按 '+'→'.'（如 0.8.7-pre.2+1 → 0.8.7.pre.2.1）。
      v = v.replaceAllMapped(RegExp(r'\+rev\.(\d+)'), (m) => '.rev${m[1]}');
      v = v.replaceAll('-', '.').replaceAll('+', '.');
      if (mounted && v.isNotEmpty) _setVersion(v);
    } catch (_) {}
  }

  // ── 开发者模式：长按「版本」10 秒开启 ──────────────────────────
  //
  // 鼠标与触摸屏通用：Listener 的 pointer down/up 对两类指针一视同仁
  // （鼠标按住左键不松 / 手指长按均可触发），且不参与手势竞技场，
  // 因此按住时仍可被外层滚动视图正常处理、不会互相抢占。
  // **计时从按下即开始（共 10s）**；为防误触，前 [_kDevHoldGate] 不显示
  // 进度条，之后才反馈进度。无悬停提示、无光标变化（保持隐藏手势）。
  void _startDevHold() {
    if (_devHolding) return;
    _devHoldTimer?.cancel();
    final sw = Stopwatch()..start();
    _devHoldTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final elapsed = sw.elapsedMilliseconds;
      final p = elapsed / _kDevHoldDuration.inMilliseconds;
      if (p >= 1) {
        t.cancel();
        _completeDevHold();
        return;
      }
      // 门槛未过：不显示进度（但计时仍在走，总时长保持 10s）。
      if (elapsed < _kDevHoldGate.inMilliseconds) return;
      if (!_devHolding) {
        _setDevHoldActive(true, progress: p);
      } else {
        _setDevHoldProgress(p);
      }
    });
  }

  void _cancelDevHold() {
    _devHoldTimer?.cancel();
    _devHoldTimer = null;
    if (mounted && _devHolding) {
      _setDevHoldActive(false);
    }
  }

  void _completeDevHold() {
    _devHoldTimer?.cancel();
    _devHoldTimer = null;
    if (mounted) _setDevHoldActive(false);
    final l10n = context.l10n;
    final notifier = ref.read(appPrefsProvider.notifier);
    if (!ref.read(appPrefsProvider).developerMode) {
      notifier.setDeveloperMode(true);
    }
    toast(
      l10n.settingsDeveloperEnabled,
      type: ToastType.success,
      duration: const Duration(milliseconds: 1600),
    );
    if (mounted) _setCategory(SettingsCategory.developer);
  }

  /// 测量选中分类在列表容器中的位置，驱动滑动指示条
  /// （对齐侧边栏 animated 模式；分类切换后经 postFrameCallback 调用）。
  void _updateCategoryIndicator() {
    if (ref.read(appPrefsProvider).sidebarNavStyle != 'animated') return;
    final hostCtx = _catHostKey.currentContext;
    final itemCtx = _catKeys[_category]?.currentContext;
    if (hostCtx == null || itemCtx == null || !itemCtx.mounted) return;
    final hostBox = hostCtx.findRenderObject() as RenderBox?;
    final itemBox = itemCtx.findRenderObject() as RenderBox?;
    if (hostBox == null || itemBox == null) return;
    final pos = itemBox.localToGlobal(Offset.zero, ancestor: hostBox);
    final left = pos.dx;
    final top = pos.dy;
    final height = itemBox.size.height;
    if (!_catIndicatorReady ||
        left != _catIndicatorLeft ||
        top != _catIndicatorTop ||
        height != _catIndicatorHeight) {
      _setCategoryIndicator(left, top, height);
    }
  }
}
