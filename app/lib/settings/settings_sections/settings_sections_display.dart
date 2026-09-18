// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 显示（ArchoeraOS per-output）──────────────────────────────────────

/// 显示设置：**每个输出一张卡片**，分辨率/刷新率、缩放、旋转各自一个下拉栏。
///
/// 数据来自协议 v5 的 per-output 快照（[SystemOsSession.displayOutputs]，原生侧
/// `apl_os_output_list` / `apl_os_output_modes`）：模式列表是该连接器的**全部**
/// 模式（分辨率 × 刷新率，带 current/preferred 标记），因此 165Hz / 60Hz 这类
/// 同分辨率不同刷新率也能分别选择。选择后用 `apl_os_output_set_*` 精确作用于
/// 该输出（而非主输出）。
///
/// 下拉栏（而非胶囊平铺）是刻意的：模式动辄数十项，平铺会溢出/换行难用。
/// 快照在页面打开、手动刷新、以及每次设置后回读一次（合成器异步生效）。
/// 缩放下拉里代表「自定义…」的哨兵值（不会与真实百分比冲突）。
const int _customScaleSentinel = -1;

class DisplaySettingsSection extends ConsumerStatefulWidget {
  const DisplaySettingsSection({super.key});

  @override
  ConsumerState<DisplaySettingsSection> createState() =>
      _DisplaySettingsSectionState();
}

class _DisplaySettingsSectionState
    extends ConsumerState<DisplaySettingsSection> {
  List<OsDisplayOutput> _outputs = const <OsDisplayOutput>[];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 读取一次输出快照。[delay] 用于设置后的回读（合成器异步更新注册表）。
  void _reload({Duration? delay}) {
    void read() {
      if (!mounted) return;
      final outputs = ref.read(osSessionControllerProvider).displayOutputs();
      setState(() {
        _outputs = outputs;
        _loaded = true;
      });
    }

    if (delay == null) {
      read();
      return;
    }
    Future<void>.delayed(delay, read);
  }

  /// 设置后在回读前先做一次乐观刷新，避免下拉栏短暂回跳。
  void _apply(
    void Function() request, {
    Duration delay = const Duration(milliseconds: 400),
  }) {
    request();
    _reload(delay: delay);
  }

  /// 自定义缩放：弹输入框（1%-400%，合成器会夹取）。
  Future<void> _customScale(OsDisplayOutput output) async {
    final l10n = context.l10n;
    final text = TextEditingController(
      text: '${(output.scaleMilli / 10).round()}',
    );
    final value = await SDialog.show<int>(
      context,
      title: l10n.systemDisplayCustomScale,
      child: TextField(
        controller: text,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: false),
        decoration: InputDecoration(
          suffixText: '%',
          border: const OutlineInputBorder(),
          hintText: '125',
        ),
        onSubmitted: (v) => Navigator.pop(context, int.tryParse(v.trim())),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, int.tryParse(text.text.trim())),
          child: Text(l10n.commonConfirm),
        ),
      ],
    );
    text.dispose();
    if (value == null || value < 1 || value > 400) return;
    _apply(
      () => ref
          .read(osSessionControllerProvider)
          .setDisplayOutputScale(output.id, value * 10),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final controller = ref.watch(osSessionControllerProvider);

    if (!_loaded) {
      return SettingSection(
        title: l10n.systemDisplayTitle,
        children: [SettingNote(text: l10n.systemDisplayLoading)],
      );
    }
    if (_outputs.isEmpty) {
      return SettingSection(
        title: l10n.systemDisplayTitle,
        children: [SettingNote(text: l10n.systemDisplayNoOutputs)],
      );
    }

    final sections = <Widget>[];
    void add(Widget section) {
      if (sections.isNotEmpty) sections.add(const SizedBox(height: 18));
      sections.add(section);
    }

    add(
      SettingSection(
        title: l10n.systemDisplayTitle,
        children: [
          SettingTile(
            icon: EtaIcons.monitorOutline,
            title: l10n.systemStatusOutput,
            subtitle: _outputs.map((o) => o.name).join(' · '),
            trailing: IconButton(
              icon: const Icon(EtaIcons.refreshOutline, size: 18),
              tooltip: l10n.commonRefresh,
              onPressed: () => _reload(),
            ),
          ),
        ],
      ),
    );

    for (final output in _outputs) {
      add(_outputCard(controller, output));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: sections,
    );
  }

  Widget _outputCard(SystemOsSession controller, OsDisplayOutput output) {
    final l10n = context.l10n;
    final title = output.primary
        ? '${output.name} · ${l10n.systemDisplayPrimaryBadge}'
        : output.name;

    // 缩放候选：常用档 + 当前值（保证下拉栏一定能显示当前档）+「自定义…」哨兵。
    final scalePercent = (output.scaleMilli / 10).round();
    final scaleOptions = <int>{
      100,
      125,
      150,
      175,
      200,
      225,
      250,
      300,
      scalePercent,
      _customScaleSentinel,
    }.toList()..sort();

    final modeOptions = [for (final m in output.modes) m.index];
    final currentMode = output.currentModeIndex;

    return SettingSection(
      title: title,
      note: output.enabled ? null : l10n.systemDisplayDisabled,
      children: [
        _DisplayDropdownRow<int>(
          label: l10n.systemDisplayMode,
          value: currentMode,
          options: modeOptions,
          labelOf: (index) => output.modes
              .firstWhere(
                (m) => m.index == index,
                orElse: () => OsDisplayMode(
                  index: index,
                  width: output.width,
                  height: output.height,
                  refreshMillihz: output.refreshMillihz,
                  isCurrent: false,
                  isPreferred: false,
                ),
              )
              .label,
          hint: output.currentModeLabel,
          onChanged: (index) =>
              _apply(() => controller.setDisplayOutputMode(output.id, index)),
        ),
        _DisplayDropdownRow<int>(
          label: l10n.systemDisplayScale,
          value: scalePercent,
          options: scaleOptions,
          labelOf: (v) =>
              v == _customScaleSentinel ? l10n.systemDisplayCustom : '$v%',
          onChanged: (v) {
            if (v == _customScaleSentinel) {
              _customScale(output);
              return;
            }
            _apply(() => controller.setDisplayOutputScale(output.id, v * 10));
          },
        ),
        _DisplayDropdownRow<int>(
          label: l10n.systemDisplayRotation,
          value: output.rotationDegrees,
          options: const [0, 90, 180, 270],
          labelOf: (v) => '$v°',
          onChanged: (v) => _apply(
            () => controller.setDisplayOutputTransform(
              output.id,
              _transformCode(v),
            ),
          ),
        ),
      ],
    );
  }
}

/// 一行「标签 + 下拉栏」（显示设置专用；下拉展开不占布局，故不会溢出）。
class _DisplayDropdownRow<T> extends StatelessWidget {
  const _DisplayDropdownRow({
    required this.label,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.hint,
  });

  final String label;

  /// 当前值；不在 [options] 中时显示 [hint]。
  final T? value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outline.withValues(alpha: 0.35)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: options.contains(value) ? value : null,
                isExpanded: true,
                borderRadius: BorderRadius.circular(10),
                hint: hint == null
                    ? null
                    : Text(hint!, overflow: TextOverflow.ellipsis),
                items: [
                  for (final option in options)
                    DropdownMenuItem<T>(
                      value: option,
                      child: Text(
                        labelOf(option),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) onChanged(v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
