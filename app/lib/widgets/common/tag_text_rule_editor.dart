// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 标签文本规则编辑控件（内置/自定义预设 + 查找替换 / 前后缀 + 正则/大小写
/// + 差异预览）。
///
/// 单曲编辑与批量编辑弹窗共用的控件：操作/选项变更经回调由宿主写回 [rule] 并
/// 经 `setState` 重建；输入内容变化经 [ListenableBuilder] 内部监听，实时刷新
/// 预览（内联高亮被删/新增片段）。自定义预设直接读写偏好（[appPrefsProvider]），
/// 因此两个宿主弹窗无需各自处理预设持久化。规则语义见
/// `services/scraper/tag_text_rule.dart`。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/scraper/tag_text_rule.dart';
import '../../stores/app_prefs.dart';
import '../dialogs/s_context_menu.dart';
import '../dialogs/s_dialog.dart';
import '../player/s_controls.dart';
import 'toast.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 常用规则预设（内置或用户自定义）。
class TagTextRulePreset {
  const TagTextRulePreset({
    required this.id,
    required this.label,
    required this.op,
    this.find = '',
    this.replace = '',
    this.affix = '',
    this.regex = false,
    this.caseSensitive = true,
    this.customName,
  });

  /// 由偏好里保存的映射还原（自定义预设）。
  factory TagTextRulePreset.fromStored(Map<String, dynamic> m) {
    final name = (m['name'] as String?) ?? '';
    return TagTextRulePreset(
      id: 'custom:$name',
      customName: name,
      label: (_) => name,
      op: TagTextOp.values.firstWhere(
        (o) => o.name == m['op'],
        orElse: () => TagTextOp.none,
      ),
      find: (m['find'] as String?) ?? '',
      replace: (m['replace'] as String?) ?? '',
      affix: (m['affix'] as String?) ?? '',
      regex: m['regex'] as bool? ?? false,
      caseSensitive: m['caseSensitive'] as bool? ?? true,
    );
  }

  final String id;
  final String Function(AppLocalizations l10n) label;
  final TagTextOp op;
  final String find;
  final String replace;
  final String affix;
  final bool regex;
  final bool caseSensitive;

  /// 自定义预设的名称（内置预设为 null）。
  final String? customName;

  TagTextRuleSnapshot get snapshot => TagTextRuleSnapshot(
    op: op,
    find: find,
    replace: replace,
    affix: affix,
    regex: regex,
    caseSensitive: caseSensitive,
  );

  /// 序列化为偏好存储映射。
  Map<String, dynamic> toStored(String name) => {
    'name': name,
    'op': op.name,
    'find': find,
    'replace': replace,
    'affix': affix,
    'regex': regex,
    'caseSensitive': caseSensitive,
  };
}

/// 内置预设列表（顺序即展示顺序）。
final List<TagTextRulePreset> tagTextRulePresets = [
  TagTextRulePreset(
    id: 'trim',
    label: (l) => l.tagEditorRulePresetTrim,
    op: TagTextOp.findReplace,
    find: r'^\s+|\s+$',
    regex: true,
  ),
  TagTextRulePreset(
    id: 'stripBrackets',
    label: (l) => l.tagEditorRulePresetStripBrackets,
    op: TagTextOp.findReplace,
    find: r'\s*[\(（\[【].*?[\)）\]】]\s*$',
    regex: true,
  ),
  TagTextRulePreset(
    id: 'stripLive',
    label: (l) => l.tagEditorRulePresetStripLive,
    op: TagTextOp.findReplace,
    find: r'\s*[\(（]\s*live\s*[\)）]',
    regex: true,
    caseSensitive: false,
  ),
  TagTextRulePreset(
    id: 'stripFeat',
    label: (l) => l.tagEditorRulePresetStripFeat,
    op: TagTextOp.findReplace,
    find: r'[\s(（]+(feat\.|ft\.|featuring).*$',
    regex: true,
    caseSensitive: false,
  ),
  TagTextRulePreset(
    id: 'indexSuffix',
    label: (l) => l.tagEditorRulePresetIndexSuffix,
    op: TagTextOp.suffix,
    affix: ' [index]',
  ),
];

class TagTextRuleEditor extends ConsumerWidget {
  const TagTextRuleEditor({
    super.key,
    required this.rule,
    required this.onOpChanged,
    required this.onRegexChanged,
    required this.onCaseChanged,
    required this.onPresetSelected,
    this.previewInput,
    this.previewVars,
  });

  final TagTextRuleControllers rule;
  final ValueChanged<TagTextOp> onOpChanged;
  final ValueChanged<bool> onRegexChanged;
  final ValueChanged<bool> onCaseChanged;
  final ValueChanged<TagTextRulePreset> onPresetSelected;

  /// 预览用样本（如首首曲目、当前编辑值）；null 则不展示预览。
  final String? previewInput;
  final Map<String, String>? previewVars;

  /// 弹出名称输入框（返回去空白后的名称；空/取消 → null）。[initial] 预填。
  Future<String?> _askPresetName(BuildContext context, String initial) async {
    final l10n = context.l10n;
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (dialogContext) => SDialog(
        title: l10n.tagEditorRulePresetSave,
        width: 360,
        actions: [
          SButton(
            label: l10n.commonCancel,
            variant: SButtonVariant.secondary,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
          SButton(
            label: l10n.commonDone,
            variant: SButtonVariant.primary,
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
          ),
        ],
        child: SInput(
          controller: controller,
          hintText: l10n.tagEditorRulePresetName,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v.trim()),
        ),
      ),
    );
    controller.dispose();
    final trimmed = result?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 保存当前规则为自定义预设（同名覆盖；其余保留）。
  Future<void> _promptSavePreset(BuildContext context, WidgetRef ref) async {
    final name = await _askPresetName(context, '');
    if (name == null) return;
    final existing = ref
        .read(appPrefsProvider)
        .tagRuleCustomPresets
        .where((m) => m['name'] != name)
        .toList();
    ref.read(appPrefsProvider.notifier).setTagRuleCustomPresets([
      ...existing,
      TagTextRulePreset(
        id: 'custom:$name',
        customName: name,
        label: (_) => name,
        op: rule.op,
        find: rule.find.text,
        replace: rule.replace.text,
        affix: rule.affix.text,
        regex: rule.regex,
        caseSensitive: rule.caseSensitive,
      ).toStored(name),
    ]);
    if (context.mounted) toast(context.l10n.tagEditorRulePresetSaved);
  }

  /// 重命名自定义预设（就地保留顺序；与既有同名时合并为其一）。
  Future<void> _renamePreset(
    BuildContext context,
    WidgetRef ref,
    TagTextRulePreset preset,
  ) async {
    final oldName = preset.customName;
    if (oldName == null) return;
    final newName = await _askPresetName(context, oldName);
    if (newName == null || newName == oldName) return;
    final list = ref.read(appPrefsProvider).tagRuleCustomPresets;
    ref
        .read(appPrefsProvider.notifier)
        .setTagRuleCustomPresets(renamePresetEntry(list, oldName, newName));
    if (context.mounted) toast(context.l10n.tagEditorRulePresetSaved);
  }

  /// 上/下移动自定义预设（[delta] = -1 / +1）。
  void _movePreset(WidgetRef ref, int index, int delta) {
    final list = ref.read(appPrefsProvider).tagRuleCustomPresets;
    ref
        .read(appPrefsProvider.notifier)
        .setTagRuleCustomPresets(movePresetEntry(list, index, delta));
  }

  /// 删除指定自定义预设。
  void _deletePreset(WidgetRef ref, TagTextRulePreset preset) {
    final name = preset.customName;
    if (name == null) return;
    final list = ref
        .read(appPrefsProvider)
        .tagRuleCustomPresets
        .where((m) => m['name'] != name)
        .toList();
    ref.read(appPrefsProvider.notifier).setTagRuleCustomPresets(list);
  }

  /// 自定义预设的「⋯」管理菜单：重命名 / 上移 / 下移 / 删除。
  void _showPresetMenu(
    BuildContext context,
    WidgetRef ref,
    TagTextRulePreset preset,
    List<TagTextRulePreset> all,
    Offset position,
  ) {
    final name = preset.customName;
    if (name == null) return;
    final l10n = context.l10n;
    final idx = all.indexWhere((p) => p.customName == name);
    SContextMenu.show(
      context,
      position: position,
      items: [
        SContextMenuItem(
          label: l10n.tagEditorRulePresetRename,
          icon: EtaIcons.editOutline,
          onTap: () => _renamePreset(context, ref, preset),
        ),
        if (idx > 0)
          SContextMenuItem(
            label: l10n.tagEditorRulePresetMoveUp,
            icon: EtaIcons.upSmall,
            onTap: () => _movePreset(ref, idx, -1),
          ),
        if (idx >= 0 && idx < all.length - 1)
          SContextMenuItem(
            label: l10n.tagEditorRulePresetMoveDown,
            icon: EtaIcons.downSmall,
            onTap: () => _movePreset(ref, idx, 1),
          ),
        SContextMenuItem(
          label: l10n.tagEditorRulePresetDelete,
          icon: EtaIcons.deleteOutline,
          danger: true,
          onTap: () => _deletePreset(ref, preset),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final customPresets = ref
        .watch(appPrefsProvider)
        .tagRuleCustomPresets
        .map(TagTextRulePreset.fromStored)
        .toList(growable: false);
    // 监听三个输入控制器：输入即刷新预览（无需宿主 setState）。
    return ListenableBuilder(
      listenable: Listenable.merge([rule.find, rule.replace, rule.affix]),
      builder: (context, _) {
        final isAffix =
            rule.op == TagTextOp.prefix || rule.op == TagTextOp.suffix;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PresetChips(
              customPresets: customPresets,
              onSelected: onPresetSelected,
              onSave: () => _promptSavePreset(context, ref),
              onMenu: (p, pos) =>
                  _showPresetMenu(context, ref, p, customPresets, pos),
            ),
            const SizedBox(height: 10),
            // 分段控件可能较宽（4 项 + 多语言标签）：横向可滚动防溢出。
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SSegmented<TagTextOp>(
                options: [
                  SSegmentedOption(TagTextOp.none, l10n.tagEditorBatchRuleNone),
                  SSegmentedOption(
                    TagTextOp.findReplace,
                    l10n.tagEditorBatchRuleFindReplace,
                  ),
                  SSegmentedOption(
                    TagTextOp.prefix,
                    l10n.tagEditorBatchRulePrefix,
                  ),
                  SSegmentedOption(
                    TagTextOp.suffix,
                    l10n.tagEditorBatchRuleSuffix,
                  ),
                ],
                selected: rule.op,
                onChanged: onOpChanged,
              ),
            ),
            if (rule.op == TagTextOp.findReplace) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: SInput(
                      controller: rule.find,
                      hintText: l10n.tagEditorBatchFindLabel,
                      clearable: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SInput(
                      controller: rule.replace,
                      hintText: l10n.tagEditorBatchReplaceLabel,
                      clearable: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 16,
                children: [
                  _RuleCheckbox(
                    label: l10n.tagEditorRuleRegex,
                    value: rule.regex,
                    onChanged: onRegexChanged,
                  ),
                  _RuleCheckbox(
                    label: l10n.tagEditorRuleCaseSensitive,
                    value: rule.caseSensitive,
                    onChanged: onCaseChanged,
                  ),
                ],
              ),
            ] else if (isAffix) ...[
              const SizedBox(height: 8),
              SInput(
                controller: rule.affix,
                hintText: l10n.tagEditorBatchAffixLabel,
              ),
              const SizedBox(height: 6),
              Text(
                l10n.tagEditorBatchTokensHint,
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (previewInput != null && previewVars != null && rule.active) ...[
              const SizedBox(height: 10),
              Text(
                l10n.tagEditorRulePreview,
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: TagTextDiffText(
                  before: previewInput!,
                  after: TagTextRuleSnapshot.of(rule)
                      .apply(previewInput!, previewVars!),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 预设一键套用（内置 + 自定义 + 保存为预设）。
class _PresetChips extends StatelessWidget {
  const _PresetChips({
    required this.customPresets,
    required this.onSelected,
    required this.onSave,
    required this.onMenu,
  });

  final List<TagTextRulePreset> customPresets;
  final ValueChanged<TagTextRulePreset> onSelected;
  final VoidCallback onSave;

  /// 打开自定义预设的管理菜单（重命名/上移/下移/删除），参数为全局坐标。
  final void Function(TagTextRulePreset preset, Offset position) onMenu;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.tagEditorRulePresets,
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final p in tagTextRulePresets)
              SButton(
                label: p.label(l10n),
                size: SButtonSize.small,
                variant: SButtonVariant.ghost,
                onPressed: () => onSelected(p),
              ),
            for (final p in customPresets)
              _CustomPresetChip(
                preset: p,
                onSelected: onSelected,
                onMenu: (pos) => onMenu(p, pos),
              ),
            SButton(
              label: l10n.tagEditorRulePresetSave,
              size: SButtonSize.small,
              variant: SButtonVariant.secondary,
              icon: EtaIcons.editOutline,
              onPressed: onSave,
            ),
          ],
        ),
      ],
    );
  }
}

/// 自定义预设 chip：名称（点击套用）+「⋯」管理菜单（重命名/上移/下移/删除）。
class _CustomPresetChip extends StatelessWidget {
  const _CustomPresetChip({
    required this.preset,
    required this.onSelected,
    required this.onMenu,
  });

  final TagTextRulePreset preset;
  final ValueChanged<TagTextRulePreset> onSelected;

  /// 报告 ⋯ 按钮的全局坐标以弹出管理菜单。
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SButton(
          label: preset.label(l10n),
          size: SButtonSize.small,
          variant: SButtonVariant.ghost,
          onPressed: () => onSelected(preset),
        ),
        Tooltip(
          message: l10n.tagEditorRulePresets,
          child: GestureDetector(
            onTapDown: (d) => onMenu(d.globalPosition),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                EtaIcons.dotsVertical,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 内联差异行：未变部分正常色，删除段（原值）删除线+错误色，
/// 新增段（结果）主色加粗。用于预览「首个样本」或列表的变换效果。
class TagTextDiffText extends StatelessWidget {
  const TagTextDiffText({super.key, required this.before, required this.after});

  final String before;
  final String after;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const base = TextStyle(fontSize: 12.5);
    if (before == after) return Text(after, style: base);

    final diff = computeTextDiff(before, after);
    return Text.rich(
      TextSpan(
        children: [
          if (diff.prefix.isNotEmpty) TextSpan(text: diff.prefix),
          if (diff.removed.isNotEmpty)
            TextSpan(
              text: diff.removed,
              style: base.copyWith(
                color: scheme.error,
                decoration: TextDecoration.lineThrough,
              ),
            ),
          if (diff.added.isNotEmpty)
            TextSpan(
              text: diff.added,
              style: base.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (diff.suffix.isNotEmpty) TextSpan(text: diff.suffix),
        ],
      ),
      maxLines: 3,
    );
  }
}

/// 紧凑复选项（正则 / 区分大小写）。
class _RuleCheckbox extends StatelessWidget {
  const _RuleCheckbox({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: Checkbox(
                value: value,
                visualDensity: VisualDensity.compact,
                onChanged: (v) => onChanged(v ?? false),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
