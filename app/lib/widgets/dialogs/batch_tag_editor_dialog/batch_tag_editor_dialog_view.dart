// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../batch_tag_editor_dialog.dart';

/// 弹窗视图：可编辑性判定 + 补丁表单 + 底部按钮。
extension _BatchTagEditorDialogView on _BatchTagEditorDialogState {
  Widget _buildBatchTagEditorDialog(BuildContext context) {
    final l10n = context.l10n;
    final editable = _hasEditable;

    final List<Widget> actions;
    final Widget body;
    if (!editable) {
      body = _buildNoEditableBody(context, l10n);
      actions = [
        SButton(
          label: l10n.commonClose,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ];
    } else if (_applying) {
      // 应用进行中：表单冻结，仅保留「停止」（当前曲目处理完后于下一项退出）。
      body = AbsorbPointer(absorbing: true, child: _buildForm(context, l10n));
      actions = [
        SButton(
          label: l10n.tagEditorBatchStop,
          variant: SButtonVariant.secondary,
          onPressed: _cancelRequested ? null : _requestStop,
        ),
      ];
    } else {
      body = _buildForm(context, l10n);
      actions = [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        SButton(
          label: l10n.tagEditorBatchApply,
          variant: SButtonVariant.primary,
          onPressed: _apply,
        ),
      ];
    }

    return SDialog(
      title: l10n.tagEditorBatchTitle,
      description: editable ? l10n.tagEditorBatchHint : null,
      // 大窗口下按比例放大（避免弹窗相对窗口显得过小）。
      width: (MediaQuery.sizeOf(context).width * 0.52).clamp(560.0, 820.0),
      actions: actions,
      child: body,
    );
  }

  Widget _buildNoEditableBody(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(EtaIcons.warningOutline, size: 18, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.tagEditorBatchNoEditable,
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.queueTrackCount(count: widget.tracks.length),
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        if (_applying) ...[
          LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
          const SizedBox(height: 8),
          Text(
            l10n.tagEditorBatchProgress(done: _done, total: _total),
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
        ],
        _BatchField(
          label: l10n.tagEditorBatchRules,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildRuleGroup(
                l10n.tagEditorBatchTitleRule,
                _titleRule,
                _sampleTitle,
              ),
              const SizedBox(height: 14),
              _buildRuleGroup(
                l10n.tagEditorBatchArtistRule,
                _artistRule,
                _sampleArtist,
              ),
            ],
          ),
        ),
        _BatchField(
          label: l10n.tagEditorFieldAlbum,
          child: SInput(controller: _album, clearable: true),
        ),
        _BatchField(
          label: l10n.tagEditorFieldAlbumArtist,
          child: SInput(controller: _albumArtist, clearable: true),
        ),
        _BatchField(
          label: l10n.tagEditorFieldComposer,
          child: SInput(controller: _composer, clearable: true),
        ),
        _BatchField(
          label: l10n.tagEditorFieldGenre,
          child: SInput(controller: _genre, clearable: true),
        ),
        _BatchField(
          label: l10n.tagEditorFieldYear,
          child: SInput(
            controller: _year,
            keyboardType: TextInputType.number,
            width: 160,
          ),
        ),
        _BatchField(
          label: l10n.tagEditorFieldCover,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SSegmented<_BatchCoverMode>(
                options: [
                  SSegmentedOption(
                    _BatchCoverMode.keep,
                    l10n.tagEditorBatchCoverKeep,
                  ),
                  SSegmentedOption(
                    _BatchCoverMode.replace,
                    l10n.tagEditorBatchCoverReplace,
                  ),
                  SSegmentedOption(
                    _BatchCoverMode.remove,
                    l10n.tagEditorBatchCoverRemove,
                  ),
                ],
                selected: _coverMode,
                onChanged: _setCoverMode,
              ),
              if (_coverMode == _BatchCoverMode.replace) ...[
                const SizedBox(height: 10),
                _buildCoverPicker(context, scheme, l10n),
              ],
            ],
          ),
        ),
        _buildPreviewList(context, l10n),
      ],
    );
  }

  /// 预览列表：前若干首样例的标题 / 艺术家内联差异高亮（随规则输入实时刷新）。
  Widget _buildPreviewList(BuildContext context, AppLocalizations l10n) {
    if (widget.tracks.isEmpty) return const SizedBox.shrink();
    if (!_titleRule.active && !_artistRule.active) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    // 监听规则输入控制器：打字即刷新（无需宿主 setState）。
    return ListenableBuilder(
      listenable: Listenable.merge([
        _titleRule.find,
        _titleRule.replace,
        _titleRule.affix,
        _artistRule.find,
        _artistRule.replace,
        _artistRule.affix,
      ]),
      builder: (context, _) {
        final samples = widget.tracks.take(6).toList(growable: false);
        final titleSnap = TagTextRuleSnapshot.of(_titleRule);
        final artistSnap = TagTextRuleSnapshot.of(_artistRule);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              l10n.tagEditorRulePreview,
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < samples.length; i++)
                    _buildPreviewRow(
                      samples[i],
                      i + 1,
                      titleSnap,
                      artistSnap,
                      scheme,
                    ),
                  if (widget.tracks.length > samples.length)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        '…',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPreviewRow(
    Track t,
    int index,
    TagTextRuleSnapshot titleSnap,
    TagTextRuleSnapshot artistSnap,
    ColorScheme scheme,
  ) {
    final vars = tagTextVars(
      TrackTags(
        title: t.title,
        artist: t.artistNames,
        album: t.album?.name ?? '',
      ),
      index,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Text(
              '$index',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TagTextDiffText(
                  before: t.title,
                  after: titleSnap.apply(t.title, vars),
                ),
                if (t.artistNames.isNotEmpty)
                  TagTextDiffText(
                    before: t.artistNames,
                    after: artistSnap.apply(t.artistNames, vars),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 字段规则分组：小号字段名 + 共享规则控件 + 预览样本。
  Widget _buildRuleGroup(
    String label,
    TagTextRuleControllers rule,
    String? previewInput,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        TagTextRuleEditor(
          rule: rule,
          onOpChanged: (op) => _setRuleOp(rule, op),
          onRegexChanged: (v) => _setRuleRegex(rule, v),
          onCaseChanged: (v) => _setRuleCase(rule, v),
          onPresetSelected: (p) => _applyPreset(rule, p),
          previewInput: previewInput,
          previewVars: _previewVars(),
        ),
      ],
    );
  }

  Widget _buildCoverPicker(
    BuildContext context,
    ColorScheme scheme,
    AppLocalizations l10n,
  ) {
    final bytes = _coverBytes;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 72,
            height: 72,
            color: scheme.surfaceContainerHighest,
            child: bytes != null
                ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
                : Icon(
                    EtaIcons.picOutline,
                    size: 28,
                    color: scheme.onSurfaceVariant,
                  ),
          ),
        ),
        const SizedBox(width: 14),
        Padding(
          padding: const EdgeInsets.only(top: 18),
          child: SButton(
            label: l10n.tagEditorCoverChange,
            icon: EtaIcons.picOutline,
            onPressed: _applying ? null : _pickCover,
          ),
        ),
      ],
    );
  }
}

/// 表单字段行：小号标签 + 控件（纵向排列）。
class _BatchField extends StatelessWidget {
  const _BatchField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}
