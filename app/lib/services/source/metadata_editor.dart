// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 「元数据（标签）编辑」能力适配器（音源注册表的组合能力之一）。
///
/// 与 `CommentPlatform` / `CollectionPlatform` 同级：详情弹窗、右键菜单、
/// 批量编辑都只面向本接口，**不再出现 `track.source == 'local'` 之类的具体
/// 平台分支**。新增「可编辑元数据」的音源 = 实现一个 [MetadataEditor] 并在
/// 其 `SourcePlatform` 适配器里返回（见 `source_platform.dart`）。
///
/// 目前只有本地文件源（`local`）具备该能力：标签读写经 `libarchoera_scraper`
/// 的 C ABI（[readTrackTags] / [writeTrackTags]），在本文件的
/// [LocalFileMetadataEditor] 中包装，UI 无需感知原生细节。
library;

import '../netease/track.dart';
import '../scraper/tag_editor_service.dart';

export '../scraper/tag_editor_service.dart'
    show TagEditorException, TrackTags, readTrackTags, writeTrackTags;

/// 单个音源的元数据编辑能力适配器。
abstract class MetadataEditor {
  /// 该曲目是否可编辑（本地文件需存在路径；在线源恒 false）。
  bool supports(Track track);

  /// 读取该曲目的可编辑标签（失败抛 [TagEditorException]）。
  Future<TrackTags> read(Track track);

  /// 写入该曲目的标签；[coverSet] 为 true 时才覆盖/清除封面。
  Future<void> write(Track track, TrackTags tags, {required bool coverSet});
}

/// 本地文件标签编辑器：包装 `libarchoera_scraper` 的单文件读写。
class LocalFileMetadataEditor implements MetadataEditor {
  const LocalFileMetadataEditor();

  @override
  bool supports(Track track) =>
      track.localPath != null && track.localPath!.isNotEmpty;

  @override
  Future<TrackTags> read(Track track) => readTrackTags(_pathOf(track));

  @override
  Future<void> write(Track track, TrackTags tags, {required bool coverSet}) =>
      writeTrackTags(_pathOf(track), tags, coverSet: coverSet);

  String _pathOf(Track track) {
    final path = track.localPath;
    if (path == null || path.isEmpty) {
      throw TagEditorException('缺少本地文件路径: ${track.title}');
    }
    return path;
  }
}
