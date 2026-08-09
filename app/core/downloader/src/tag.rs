// ============================================================
// v2 增强：下载完成后写基础音乐标签（title / artist / album）
//
// 使用 lofty（MIT/Apache-2.0）原地写入。mp3 → ID3v2，flac → Vorbis
// Comment。写标签失败**不阻断**下载（仅记录日志，文件仍有效）。
// ============================================================

use std::path::Path;

use lofty::config::WriteOptions;
use lofty::file::AudioFile;
use lofty::prelude::*;
use lofty::probe::Probe;
use lofty::tag::Accessor;

use crate::models::EnqueueRequest;

/// 给下载完成的文件写标签。全部字段为空时跳过；任何错误返回 Err（不阻断）。
pub fn write_tags(path: &Path, req: &EnqueueRequest) -> Result<(), String> {
    let title = req.title.trim();
    let artist = req.artist.trim();
    let album = req.album.as_deref().unwrap_or("").trim();
    if title.is_empty() && artist.is_empty() && album.is_empty() {
        return Ok(());
    }

    let mut tagged = Probe::open(path)
        .map_err(|e| format!("Probe 打开失败: {e}"))?
        .read()
        .map_err(|e| format!("解析标签失败: {e}"))?;

    // 优先主标签，其次第一个可用标签（无标签文件会返回 None）
    {
        let tag = if tagged.primary_tag().is_some() {
            tagged.primary_tag_mut().unwrap()
        } else {
            tagged
                .first_tag_mut()
                .ok_or_else(|| "无可用标签槽位".to_string())?
        };
        if !title.is_empty() {
            tag.set_title(title.to_string());
        }
        if !artist.is_empty() {
            tag.set_artist(artist.to_string());
        }
        if !album.is_empty() {
            tag.set_album(album.to_string());
        }
    } // 结束 tag 借用

    tagged
        .save_to_path(path, WriteOptions::default())
        .map_err(|e| format!("写标签失败: {e}"))
}
