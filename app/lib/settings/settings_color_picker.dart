import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../widgets/common/glass_surface.dart';

/// 自定义主色选择弹窗（HSV 面板 + 色相滑条 + 十六进制输入）。
///
/// 由外观设置「自定义主色」触发（showDialog 返回所选 [Color]，null = 取消）。
class AccentPickerDialog extends StatefulWidget {
  const AccentPickerDialog({
    super.key,
    required this.initial,
    required this.l10n,
  });
  final Color initial;
  final AppLocalizations l10n;

  @override
  State<AccentPickerDialog> createState() => _AccentPickerDialogState();
}

class _AccentPickerDialogState extends State<AccentPickerDialog> {
  late HSVColor _hsv;
  late final TextEditingController _hexCtrl;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
    _hexCtrl = TextEditingController(text: _hexOf(widget.initial));
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  static String _hexOf(Color c) {
    final v = c.toARGB32() & 0xFFFFFF;
    return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  void _setHsv(HSVColor v) {
    setState(() {
      _hsv = v;
      _hexCtrl.text = _hexOf(v.toColor());
    });
  }

  void _applyHex(String raw) {
    final s = raw.trim().replaceFirst('#', '');
    if (s.length != 6) return;
    final v = int.tryParse(s, radix: 16);
    if (v == null) return;
    setState(() {
      _hsv = HSVColor.fromColor(Color(0xFF000000 | v));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = widget.l10n;
    final color = _hsv.toColor();
    // Dialog 透明根 + GlassDialogSurface 只包内容（对齐 SDialog）：
    // AlertDialog 自身就是 Dialog，再嵌套进外层 Dialog 会布局异常全屏；
    // GlassDialogSurface 若直接作 showDialog 根则会铺满窗口成「全遮罩」。
    return Dialog(
      insetPadding: const EdgeInsets.all(48),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: GlassDialogSurface(
        radius: BorderRadius.circular(24),
        color: scheme.surfaceContainerHighest,
        child: SizedBox(
          width: 320,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.settingsPickerTitle,
                  style: Theme.of(context).dialogTheme.titleTextStyle,
                ),
                const SizedBox(height: 16),
                _SvPanel(hsv: _hsv, onChanged: _setHsv),
                const SizedBox(height: 8),
                Slider(
                  value: _hsv.hue,
                  min: 0,
                  max: 360,
                  onChanged: (h) => _setHsv(_hsv.withHue(h)),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color,
                        border: Border.all(
                          color: theme.colorScheme.outline.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _hexCtrl,
                        onChanged: _applyHex,
                        decoration: InputDecoration(
                          labelText: l10n.settingsPickerHexLabel,
                          isDense: true,
                        ),
                        textInputAction: TextInputAction.done,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l10n.commonCancel),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, color),
                      child: Text(l10n.settingsApply),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// HSV 取色面板（横轴饱和度 / 纵轴明度，拖拽更新）。
class _SvPanel extends StatelessWidget {
  const _SvPanel({required this.hsv, required this.onChanged});
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  @override
  Widget build(BuildContext context) {
    final base = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    return AspectRatio(
      aspectRatio: 2,
      child: LayoutBuilder(
        builder: (context, c) {
          final size = Size(c.maxWidth, c.maxHeight);
          return GestureDetector(
            onPanDown: (d) => _pick(d.localPosition, size),
            onPanUpdate: (d) => _pick(d.localPosition, size),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.white, base],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      ),
                    ),
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.transparent, Colors.black],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                  Positioned(
                    left: hsv.saturation * c.maxWidth - 7,
                    top: (1 - hsv.value) * c.maxHeight - 7,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: 3,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _pick(Offset pos, Size size) {
    final s = (pos.dx / size.width).clamp(0.0, 1.0);
    final v = (1 - pos.dy / size.height).clamp(0.0, 1.0);
    onChanged(hsv.withSaturation(s).withValue(v));
  }
}
