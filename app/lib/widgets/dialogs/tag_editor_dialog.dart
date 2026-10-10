// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 本地媒体元数据（标签）编辑弹窗（媒体库右键菜单「编辑元数据」）。
///
/// 通过 `TagEditorService` 的 `readTrackTags` / `writeTrackTags` 读写单文件
/// 标签：标题 / 艺术家 / 专辑 / 专辑艺术家 / 作曲家 / 流派 / 音轨号 / 碟片号 /
/// 年份 / 歌词 / 封面（更换或移除）。仅对本地文件（[Track.localPath] 非空）
/// 可用；读取失败或格式不支持时展示错误而非表单。
///
/// 入口 [showTagEditorDialog]；保存成功后触发一次增量扫描刷新曲库列表。
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
import '../../services/scraper/tag_editor_service.dart';
import '../../services/scraper/tag_text_rule.dart';
import '../../stores/app_prefs.dart';
import '../../utils/format.dart';
import '../common/tag_text_rule_editor.dart';
import '../common/toast.dart';
import '../player/s_controls.dart';
import 's_dialog.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'tag_editor_dialog/tag_editor_dialog_view.dart';

/// 打开本地媒体元数据编辑弹窗。
Future<void> showTagEditorDialog(BuildContext context, {required Track track}) {
  return showDialog<void>(
    context: context,
    useRootNavigator:
        false, // 必须 false：StatefulShellRoute.indexedStack 下用分支 Navigator
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (_) => TagEditorDialog(track: track),
  );
}

/// 本地媒体标签编辑弹窗主体。
class TagEditorDialog extends ConsumerStatefulWidget {
  const TagEditorDialog({super.key, required this.track});

  final Track track;

  @override
  ConsumerState<TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends ConsumerState<TagEditorDialog> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _artist = TextEditingController();
  final TextEditingController _album = TextEditingController();
  final TextEditingController _albumArtist = TextEditingController();
  final TextEditingController _composer = TextEditingController();
  final TextEditingController _genre = TextEditingController();
  final TextEditingController _trackNumber = TextEditingController();
  final TextEditingController _discNumber = TextEditingController();
  final TextEditingController _year = TextEditingController();
  final TextEditingController _lyrics = TextEditingController();

  /// 当前编辑中的封面二进制（null = 无封面）。
  Uint8List? _coverBytes;

  /// 当前编辑中的封面 MIME（如 `image/jpeg`）。
  String _coverMime = '';

  /// 封面是否被改动（决定写入时是否覆盖封面字段）。
  bool _coverDirty = false;

  bool _loading = true;
  bool _saving = false;

  /// 是否正在在线刮削（单曲多源查询）。
  bool _scraping = false;

  /// 错误文案（null = 无错误）；读取失败/缺少路径时展示并只保留关闭按钮。
  String? _error;

  /// 文本规则（标题 / 艺术家就地变换）及其作用目标：0=标题 1=艺术家 2=两者。
  final TagTextRuleControllers _rule = TagTextRuleControllers();
  int _ruleTarget = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _album.dispose();
    _albumArtist.dispose();
    _composer.dispose();
    _genre.dispose();
    _trackNumber.dispose();
    _discNumber.dispose();
    _year.dispose();
    _lyrics.dispose();
    _rule.dispose();
    super.dispose();
  }

  /// 读取本地文件标签并填充表单（initState 调用，故经 [l10nProvider] 取文案）。
  Future<void> _load() async {
    final l10n = ref.read(l10nProvider);
    final path = widget.track.localPath;
    if (path == null || path.isEmpty) {
      // 首帧尚未构建（initState 同步段）：直接赋值，无需 setState。
      _error = l10n.tagEditorNoPath;
      _loading = false;
      return;
    }
    try {
      final tags = await readTrackTags(path);
      if (!mounted) return;
      setState(() {
        _applyTags(tags);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '${l10n.tagEditorLoadFailed}: $e';
        _loading = false;
      });
    }
  }

  /// 用读出的标签填充各控制器与封面状态。
  void _applyTags(TrackTags tags) {
    _title.text = tags.title;
    _artist.text = tags.artist;
    _album.text = tags.album;
    _albumArtist.text = tags.albumArtist;
    _composer.text = tags.composer;
    _genre.text = tags.genre;
    _lyrics.text = tags.lyrics;
    _trackNumber.text = tags.trackNumber > 0 ? '${tags.trackNumber}' : '';
    _discNumber.text = tags.discNumber > 0 ? '${tags.discNumber}' : '';
    _year.text = tags.year > 0 ? '${tags.year}' : '';
    _coverBytes = tags.coverBytes;
    _coverMime = tags.coverMime;
    _coverDirty = false;
  }

  /// 选择封面图片文件（读取字节并据扩展名推断 MIME）。
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
      // 文件选择器不可用时静默忽略。
      return;
    }
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() {
      _coverBytes = bytes;
      _coverMime = _mimeForName(file!.name);
      _coverDirty = true;
    });
  }

  /// 移除封面（置空并标记改动；保存后由写入端清除文件封面）。
  void _removeCover() {
    setState(() {
      _coverBytes = null;
      _coverMime = '';
      _coverDirty = true;
    });
  }

  /// 按扩展名推断封面 MIME。
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

  /// 切换文本规则操作。
  void _setRuleOp(TagTextOp op) {
    if (op == _rule.op) return;
    setState(() => _rule.op = op);
  }

  /// 切换规则「正则」/「区分大小写」选项。
  void _setRuleRegex(bool value) {
    if (_rule.regex == value) return;
    setState(() => _rule.regex = value);
  }

  void _setRuleCase(bool value) {
    if (_rule.caseSensitive == value) return;
    setState(() => _rule.caseSensitive = value);
  }

  /// 套用预设：写入操作 + 参数 + 正则/大小写选项。
  void _applyPreset(TagTextRulePreset preset) {
    final snap = preset.snapshot;
    setState(() {
      _rule.op = snap.op;
      _rule.find.text = snap.find;
      _rule.replace.text = snap.replace;
      _rule.affix.text = snap.affix;
      _rule.regex = snap.regex;
      _rule.caseSensitive = snap.caseSensitive;
    });
  }

  /// 预览用占位符变量（取当前编辑值）。
  Map<String, String> _previewVars() => tagTextVars(
    TrackTags(
      title: _title.text,
      artist: _artist.text,
      album: _album.text,
      albumArtist: _albumArtist.text,
      trackNumber: int.tryParse(_trackNumber.text.trim()) ?? 0,
      discNumber: int.tryParse(_discNumber.text.trim()) ?? 0,
      year: int.tryParse(_year.text.trim()) ?? 0,
    ),
    1,
  );

  /// 切换规则作用目标：0=标题 1=艺术家 2=两者。
  void _setRuleTarget(int target) {
    if (target == _ruleTarget) return;
    setState(() => _ruleTarget = target);
  }

  /// 把文本规则就地应用到标题 / 艺术家（单曲：[index] 恒为 1，
  /// `[title]`/`[artist]` 等取变换前的当前值）。
  void _applyRule() {
    if (!_rule.active) return;
    final vars = tagTextVars(
      TrackTags(
        title: _title.text,
        artist: _artist.text,
        album: _album.text,
        albumArtist: _albumArtist.text,
        trackNumber: int.tryParse(_trackNumber.text.trim()) ?? 0,
        discNumber: int.tryParse(_discNumber.text.trim()) ?? 0,
        year: int.tryParse(_year.text.trim()) ?? 0,
      ),
      1,
    );
    final snap = TagTextRuleSnapshot.of(_rule);
    setState(() {
      if (_ruleTarget == 0 || _ruleTarget == 2) {
        _title.text = snap.apply(_title.text, vars);
      }
      if (_ruleTarget == 1 || _ruleTarget == 2) {
        _artist.text = snap.apply(_artist.text, vars);
      }
    });
  }

  /// 在线刮削单曲：按当前表单值（标题 / 艺术家，缺失回退曲目模型）多源查询，
  /// 命中后把结果填入表单供审阅（不直接写文件）。数据源与封面/歌词开关沿用
  /// 「设置 → 刮削」的偏好。
  Future<void> _scrape() async {
    final l10n = ref.read(l10nProvider);
    if (_scraping) return;
    final queryTitle = _title.text.trim().isNotEmpty
        ? _title.text.trim()
        : widget.track.title;
    final queryArtist = _artist.text.trim().isNotEmpty
        ? _artist.text.trim()
        : widget.track.artistNames;
    if (queryTitle.isEmpty && queryArtist.isEmpty) {
      toast(l10n.tagEditorScrapeNeedQuery, type: ToastType.warning);
      return;
    }
    setState(() => _scraping = true);
    final prefs = ref.read(appPrefsProvider);
    try {
      final result = await scrapeTrackForEdit(
        title: queryTitle,
        artist: queryArtist,
        album: _album.text.trim(),
        albumArtist: _albumArtist.text.trim(),
        durationMs: widget.track.duration,
        filePath: widget.track.localPath ?? '',
        options: TrackScrapeOptions(
          musicBrainz: prefs.scrapeUseMusicBrainz,
          deezer: prefs.scrapeUseDeezer,
          itunes: prefs.scrapeUseItunes,
          netease: prefs.scrapeUseNetease,
          qqMusic: prefs.scrapeUseQQMusic,
          kugou: prefs.scrapeUseKugou,
          kuwo: prefs.scrapeUseKuwo,
          migu: prefs.scrapeUseMigu,
          acoustId: prefs.scrapeUseAcoustID,
          fetchCover: prefs.scrapeEmbedCover,
          fetchLyrics: prefs.scrapeEmbedLyrics,
          workers: prefs.scrapeWorkers,
        ),
      );
      if (!mounted) return;
      if (!result.found) {
        setState(() => _scraping = false);
        toast(l10n.tagEditorScrapeNotFound, type: ToastType.warning);
        return;
      }
      setState(() {
        _scraping = false;
        _applyScraped(result);
      });
      toast(l10n.tagEditorScrapeDone, type: ToastType.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _scraping = false);
      toast('${l10n.tagEditorScrapeFailed}: $e', type: ToastType.error);
    }
  }

  /// 用刮削结果填充表单：只覆盖有值的字段（保守合并，保留用户已填内容）；
  /// 封面仅在抓到新封面时替换并标记改动。
  void _applyScraped(ScrapedTrack r) {
    if (r.title.isNotEmpty) _title.text = r.title;
    if (r.artist.isNotEmpty) _artist.text = r.artist;
    if (r.album.isNotEmpty) _album.text = r.album;
    if (r.albumArtist.isNotEmpty) _albumArtist.text = r.albumArtist;
    if (r.composer.isNotEmpty) _composer.text = r.composer;
    if (r.genre.isNotEmpty) _genre.text = r.genre;
    if (r.trackNumber > 0) _trackNumber.text = '${r.trackNumber}';
    if (r.discNumber > 0) _discNumber.text = '${r.discNumber}';
    if (r.year > 0) _year.text = '${r.year}';
    if (r.lyrics.isNotEmpty) _lyrics.text = r.lyrics;
    final cover = r.coverBytes;
    if (cover != null) {
      _coverBytes = cover;
      _coverMime = r.coverMime;
      _coverDirty = true;
    }
  }

  /// 保存：构造 [TrackTags] 写回文件、提示并触发增量扫描刷新曲库。
  Future<void> _save() async {
    final l10n = ref.read(l10nProvider);
    final path = widget.track.localPath;
    if (path == null || path.isEmpty) {
      setState(() => _error = l10n.tagEditorNoPath);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final tags = TrackTags(
      title: _title.text.trim(),
      artist: _artist.text.trim(),
      album: _album.text.trim(),
      albumArtist: _albumArtist.text.trim(),
      composer: _composer.text.trim(),
      genre: _genre.text.trim(),
      lyrics: _lyrics.text,
      coverMime: _coverMime,
      trackNumber: int.tryParse(_trackNumber.text.trim()) ?? 0,
      discNumber: int.tryParse(_discNumber.text.trim()) ?? 0,
      year: int.tryParse(_year.text.trim()) ?? 0,
      coverBytes: _coverBytes,
      hasCover: _coverBytes != null,
    );
    try {
      await writeTrackTags(path, tags, coverSet: _coverDirty);
      if (!mounted) return;
      toast(l10n.tagEditorSaved, type: ToastType.success);
      // 刷新曲库，使编辑后的行反映新标签（扫描完成后会重载列表）。
      try {
        unawaited(
          ref.read(libraryStoreProvider.notifier).startScan(incremental: true),
        );
      } catch (_) {
        // 刷新失败不影响保存结果。
      }
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = null;
      });
      toast(l10n.tagEditorSaveFailed, type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) => _buildTagEditorDialog(context);
}
