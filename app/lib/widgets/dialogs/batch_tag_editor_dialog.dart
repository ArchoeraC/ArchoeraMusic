// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 批量元数据（标签）编辑弹窗（本地库多选批量操作栏「编辑元数据」）。
///
/// **补丁语义**：与单曲编辑弹窗的「全量覆盖」不同，本弹窗只把用户**填写**
/// 的字段应用到所选曲目，留空字段保持每首原值。实现为对每首曲目
/// 「读取 → 合并补丁 → 写入」，因此不会误清空未填写的字段。
///
/// 可编辑性经音源注册表 [SourcePlatform.metadataEditor] 判定（见
/// `services/source/metadata_editor.dart`），本文件不含 `source == 'local'`
/// 之类的具体平台分支。入口 [showBatchTagEditorDialog]。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/netease/track.dart';
import '../../services/scanner/library_store.dart';
import '../../services/scraper/tag_text_rule.dart';
import '../../services/source/metadata_editor.dart';
import '../../services/source/source_platform.dart';
import '../common/tag_text_rule_editor.dart';
import '../common/toast.dart';
import '../player/s_controls.dart';
import 's_dialog.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'batch_tag_editor_dialog/batch_tag_editor_dialog_view.dart';

/// 打开批量元数据编辑弹窗。[tracks] 为当前所选曲目。
Future<void> showBatchTagEditorDialog(
  BuildContext context, {
  required List<Track> tracks,
}) {
  return showDialog<void>(
    context: context,
    useRootNavigator:
        false, // 必须 false：StatefulShellRoute.indexedStack 下用分支 Navigator
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (_) => BatchTagEditorDialog(tracks: tracks),
  );
}

/// 批量元数据编辑弹窗主体。
class BatchTagEditorDialog extends ConsumerStatefulWidget {
  const BatchTagEditorDialog({super.key, required this.tracks});

  final List<Track> tracks;

  @override
  ConsumerState<BatchTagEditorDialog> createState() =>
      _BatchTagEditorDialogState();
}

/// 封面处理方式（批量补丁）。
enum _BatchCoverMode { keep, replace, remove }

/// 应用时的补丁快照（应用过程中用户改表单不影响在途项）。
class _BatchPatch {
  const _BatchPatch({
    required this.album,
    required this.albumArtist,
    required this.composer,
    required this.genre,
    required this.year,
    required this.coverMode,
    required this.coverBytes,
    required this.coverMime,
    required this.titleRule,
    required this.artistRule,
  });

  final String? album;
  final String? albumArtist;
  final String? composer;
  final String? genre;
  final int? year;
  final _BatchCoverMode coverMode;
  final Uint8List? coverBytes;
  final String coverMime;

  /// 规则快照（控制器值在 `_snapshot` 时固定）。
  final TagTextRuleSnapshot titleRule;
  final TagTextRuleSnapshot artistRule;

  /// 是否需要覆盖/清除封面。
  bool get coverSet => coverMode != _BatchCoverMode.keep;

  /// 把补丁合并到 [cur]（未填字段保持 [cur]）。
  TrackTags merge(TrackTags cur, int index) {
    final vars = tagTextVars(cur, index);
    return TrackTags(
      title: titleRule.apply(cur.title, vars),
      artist: artistRule.apply(cur.artist, vars),
      album: album ?? cur.album,
      albumArtist: albumArtist ?? cur.albumArtist,
      composer: composer ?? cur.composer,
      genre: genre ?? cur.genre,
      // 音轨号 / 碟片号逐曲不同，批量不动。
      trackNumber: cur.trackNumber,
      discNumber: cur.discNumber,
      year: year ?? cur.year,
      lyrics: cur.lyrics,
      coverMime: coverMode == _BatchCoverMode.replace
          ? coverMime
          : cur.coverMime,
      coverBytes: switch (coverMode) {
        _BatchCoverMode.remove => null,
        _BatchCoverMode.replace => coverBytes,
        _BatchCoverMode.keep => cur.coverBytes,
      },
      hasCover: switch (coverMode) {
        _BatchCoverMode.remove => false,
        _BatchCoverMode.replace => coverBytes != null,
        _BatchCoverMode.keep => cur.hasCover,
      },
    );
  }
}

class _BatchTagEditorDialogState extends ConsumerState<BatchTagEditorDialog> {
  final TextEditingController _album = TextEditingController();
  final TextEditingController _albumArtist = TextEditingController();
  final TextEditingController _composer = TextEditingController();
  final TextEditingController _genre = TextEditingController();
  final TextEditingController _year = TextEditingController();

  /// 标题 / 艺术家逐曲文本规则。
  final TagTextRuleControllers _titleRule = TagTextRuleControllers();
  final TagTextRuleControllers _artistRule = TagTextRuleControllers();

  _BatchCoverMode _coverMode = _BatchCoverMode.keep;
  Uint8List? _coverBytes;
  String _coverMime = '';

  bool _applying = false;

  /// 应用进度（已完成 / 总数）与停止请求。
  int _done = 0;
  int _total = 0;
  bool _cancelRequested = false;

  /// 所选曲目中是否存在可编辑项（经音源注册表判定）。
  bool get _hasEditable =>
      widget.tracks.any((t) => sourcePlatform(t.source).canEditMetadata(t));

  @override
  void dispose() {
    _album.dispose();
    _albumArtist.dispose();
    _composer.dispose();
    _genre.dispose();
    _year.dispose();
    _titleRule.dispose();
    _artistRule.dispose();
    super.dispose();
  }

  /// 选择封面图片（仅在「更换封面」模式下有意义）。
  Future<void> _pickCover() async {
    XFile? file;
    try {
      file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Image',
            extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
          ),
        ],
      );
    } catch (_) {
      return;
    }
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() {
      _coverBytes = bytes;
      _coverMime = _mimeForName(file!.name);
    });
  }

  String _mimeForName(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'bmp' => 'image/bmp',
      _ => 'application/octet-stream',
    };
  }

  /// 生成补丁快照（应用开始时固定，避免在途被表单改动影响）。
  _BatchPatch _snapshot() {
    final year = int.tryParse(_year.text.trim());
    return _BatchPatch(
      album: _nonEmpty(_album),
      albumArtist: _nonEmpty(_albumArtist),
      composer: _nonEmpty(_composer),
      genre: _nonEmpty(_genre),
      year: (year != null && year > 0) ? year : null,
      coverMode: _coverMode,
      coverBytes: _coverBytes,
      coverMime: _coverMime,
      titleRule: TagTextRuleSnapshot.of(_titleRule),
      artistRule: TagTextRuleSnapshot.of(_artistRule),
    );
  }

  String? _nonEmpty(TextEditingController c) {
    final v = c.text.trim();
    return v.isEmpty ? null : v;
  }

  /// 切换封面处理方式（应用进行中忽略）。
  void _setCoverMode(_BatchCoverMode mode) {
    if (_applying || mode == _coverMode) return;
    setState(() => _coverMode = mode);
  }

  /// 切换某字段的文本规则操作（应用进行中忽略）。
  void _setRuleOp(TagTextRuleControllers rule, TagTextOp op) {
    if (_applying || rule.op == op) return;
    setState(() => rule.op = op);
  }

  /// 切换规则「正则」/「区分大小写」选项（应用进行中忽略）。
  void _setRuleRegex(TagTextRuleControllers rule, bool value) {
    if (_applying || rule.regex == value) return;
    setState(() => rule.regex = value);
  }

  void _setRuleCase(TagTextRuleControllers rule, bool value) {
    if (_applying || rule.caseSensitive == value) return;
    setState(() => rule.caseSensitive = value);
  }

  /// 套用预设：写入操作 + 参数 + 正则/大小写选项。
  void _applyPreset(TagTextRuleControllers rule, TagTextRulePreset preset) {
    if (_applying) return;
    final snap = preset.snapshot;
    setState(() {
      rule.op = snap.op;
      rule.find.text = snap.find;
      rule.replace.text = snap.replace;
      rule.affix.text = snap.affix;
      rule.regex = snap.regex;
      rule.caseSensitive = snap.caseSensitive;
    });
  }

  /// 预览样本（首首曲目的标题 / 艺术家）。
  String? get _sampleTitle =>
      widget.tracks.isEmpty ? null : widget.tracks.first.title;

  String? get _sampleArtist =>
      widget.tracks.isEmpty ? null : widget.tracks.first.artistNames;

  /// 预览用占位符变量（取首首曲目元数据）。
  Map<String, String> _previewVars() {
    final t = widget.tracks.isEmpty ? null : widget.tracks.first;
    return tagTextVars(
      TrackTags(
        title: t?.title ?? '',
        artist: t?.artistNames ?? '',
        album: t?.album?.name ?? '',
      ),
      1,
    );
  }

  /// 请求停止批量应用（在当前曲目处理完后于下一项边界退出）。
  void _requestStop() {
    if (!_applying || _cancelRequested) return;
    setState(() => _cancelRequested = true);
  }

  Future<void> _apply() async {
    final l10n = ref.read(l10nProvider);
    final patch = _snapshot();
    setState(() {
      _applying = true;
      _cancelRequested = false;
      _done = 0;
      _total = widget.tracks.length;
    });
    var success = 0;
    var failed = 0;
    for (var i = 0; i < widget.tracks.length; i++) {
      if (_cancelRequested) break;
      final t = widget.tracks[i];
      final editor = sourcePlatform(t.source).metadataEditor;
      if (editor == null || !editor.supports(t)) {
        failed++;
      } else {
        try {
          final cur = await editor.read(t);
          await editor.write(
            t,
            patch.merge(cur, i + 1),
            coverSet: patch.coverSet,
          );
          success++;
        } catch (_) {
          failed++;
        }
      }
      if (mounted) setState(() => _done = i + 1);
    }
    if (!mounted) return;
    toast(
      l10n.tagEditorBatchDone(success: success, failed: failed),
      type: failed > 0 ? ToastType.warning : ToastType.success,
    );
    // 触发一次增量扫描刷新曲库（扫描完成后重载列表）。
    try {
      unawaited(
        ref.read(libraryStoreProvider.notifier).startScan(incremental: true),
      );
    } catch (_) {}
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => _buildBatchTagEditorDialog(context);
}
