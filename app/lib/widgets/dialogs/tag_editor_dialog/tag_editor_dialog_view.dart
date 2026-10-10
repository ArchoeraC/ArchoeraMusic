// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../tag_editor_dialog.dart';

/// 弹窗视图：按加载 / 错误 / 表单三态构建 [SDialog]。
extension _TagEditorDialogView on _TagEditorDialogState {
  Widget _buildTagEditorDialog(BuildContext context) {
    final l10n = context.l10n;

    final Widget body;
    final List<Widget> actions;
    if (_loading) {
      body = _buildLoadingBody(l10n);
      actions = [_closeButton(context, l10n)];
    } else if (_error != null) {
      body = _buildErrorBody(context, l10n);
      actions = [_closeButton(context, l10n)];
    } else {
      body = _buildForm(context, l10n);
      actions = [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        SButton(
          label: l10n.tagEditorSave,
          variant: SButtonVariant.primary,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ];
    }

    return SDialog(
      title: l10n.tagEditorTitle,
      // 大窗口下按比例放大（避免弹窗相对窗口显得过小）。
      width: (MediaQuery.sizeOf(context).width * 0.52).clamp(560.0, 820.0),
      actions: actions,
      child: body,
    );
  }

  SButton _closeButton(BuildContext context, AppLocalizations l10n) => SButton(
    label: l10n.commonClose,
    variant: SButtonVariant.secondary,
    onPressed: () => Navigator.of(context).pop(),
  );

  Widget _buildLoadingBody(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(l10n.tagEditorLoading, style: const TextStyle(fontSize: 13.5)),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBody(BuildContext context, AppLocalizations l10n) {
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
              _error ?? l10n.tagEditorLoadFailed,
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
        Row(
          children: [
            SButton(
              label: _scraping ? l10n.tagEditorScraping : l10n.tagEditorScrape,
              icon: EtaIcons.magic3,
              variant: SButtonVariant.secondary,
              loading: _scraping,
              onPressed: (_scraping || _saving) ? null : _scrape,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.tagEditorScrapeHint,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _TagEditorField(
          label: l10n.tagEditorFieldTitle,
          child: SInput(controller: _title, clearable: true),
        ),
        _TagEditorField(
          label: l10n.tagEditorFieldArtist,
          child: SInput(controller: _artist, clearable: true),
        ),
        _TagEditorField(
          label: l10n.tagEditorBatchRules,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SSegmented<int>(
                  options: [
                    SSegmentedOption(0, l10n.tagEditorFieldTitle),
                    SSegmentedOption(1, l10n.tagEditorFieldArtist),
                    SSegmentedOption(2, l10n.tagEditorRuleTargetBoth),
                  ],
                  selected: _ruleTarget,
                  onChanged: _setRuleTarget,
                ),
              ),
              const SizedBox(height: 10),
              TagTextRuleEditor(
                rule: _rule,
                onOpChanged: _setRuleOp,
                onRegexChanged: _setRuleRegex,
                onCaseChanged: _setRuleCase,
                onPresetSelected: _applyPreset,
                previewInput: _ruleTarget == 1 ? _artist.text : _title.text,
                previewVars: _previewVars(),
              ),
              const SizedBox(height: 10),
              SButton(
                label: l10n.tagEditorRuleApply,
                icon: EtaIcons.editOutline,
                variant: SButtonVariant.secondary,
                onPressed: (_rule.active && !_saving) ? _applyRule : null,
              ),
            ],
          ),
        ),
        _TagEditorField(
          label: l10n.tagEditorFieldAlbum,
          child: SInput(controller: _album, clearable: true),
        ),
        _TagEditorField(
          label: l10n.tagEditorFieldAlbumArtist,
          child: SInput(controller: _albumArtist, clearable: true),
        ),
        _TagEditorField(
          label: l10n.tagEditorFieldComposer,
          child: SInput(controller: _composer, clearable: true),
        ),
        _TagEditorField(
          label: l10n.tagEditorFieldGenre,
          child: SInput(controller: _genre, clearable: true),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _TagEditorField(
                label: l10n.tagEditorFieldTrackNumber,
                child: SInput(
                  controller: _trackNumber,
                  keyboardType: TextInputType.number,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _TagEditorField(
                label: l10n.tagEditorFieldDiscNumber,
                child: SInput(
                  controller: _discNumber,
                  keyboardType: TextInputType.number,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _TagEditorField(
                label: l10n.tagEditorFieldYear,
                child: SInput(
                  controller: _year,
                  keyboardType: TextInputType.number,
                ),
              ),
            ),
          ],
        ),
        _TagEditorField(
          label: l10n.tagEditorFieldLyrics,
          child: TextField(
            controller: _lyrics,
            minLines: 3,
            maxLines: 8,
            style: const TextStyle(fontSize: 13.5),
            cursorColor: scheme.primary,
          ),
        ),
        _TagEditorField(
          label: l10n.tagEditorFieldCover,
          child: _buildCoverEditor(context, scheme, l10n),
        ),
        if (widget.track.duration > 0)
          _TagEditorField(
            label: l10n.tagEditorDuration,
            child: Text(
              formatMs(widget.track.duration),
              style: const TextStyle(fontSize: 13.5),
            ),
          ),
      ],
    );
  }

  Widget _buildCoverEditor(
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
            width: 96,
            height: 96,
            color: scheme.surfaceContainerHighest,
            child: bytes != null
                ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
                : Icon(
                    EtaIcons.picOutline,
                    size: 32,
                    color: scheme.onSurfaceVariant,
                  ),
          ),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SButton(
              label: l10n.tagEditorCoverChange,
              icon: EtaIcons.picOutline,
              onPressed: _saving ? null : _pickCover,
            ),
            if (bytes != null) ...[
              const SizedBox(height: 8),
              SButton(
                label: l10n.tagEditorCoverRemove,
                icon: EtaIcons.deleteOutline,
                variant: SButtonVariant.ghost,
                onPressed: _saving ? null : _removeCover,
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// 表单字段行：小号标签 + 控件（纵向排列）。
class _TagEditorField extends StatelessWidget {
  const _TagEditorField({required this.label, required this.child});

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
