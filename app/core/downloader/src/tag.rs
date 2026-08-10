// ============================================================
// v2.1 增强：下载完成后写完整音乐标签
//
// 使用 lofty（MIT/Apache-2.0）原地写入。mp3 → ID3v2，flac → Vorbis
// Comment。支持：
//   - 基础字段：title / artist / album（Accessor）
//   - 歌词：ID3v2 USLT / Vorbis LYRICS（ItemKey::Lyrics）
//   - 封面：ID3v2 APIC / Vorbis METADATA_BLOCK_PICTURE
// 无标签文件自动新建对应槽位。写标签失败**不阻断**下载（仅记录日志）。
// ============================================================

use std::path::{Path, PathBuf};

use lofty::config::WriteOptions;
use lofty::file::{AudioFile, FileType, TaggedFileExt};
use lofty::picture::{MimeType, Picture, PictureType};
use lofty::probe::Probe;
use lofty::tag::{Accessor, ItemKey, Tag, TagType};

/// 待写入的标签内容（由 metadata::enrich_file 产出）
pub struct TagContent<'a> {
    pub title: &'a str,
    pub artist: &'a str,
    pub album: &'a str,
    pub lyrics: Option<&'a str>,
    /// (图片字节, mime)
    pub cover: Option<(&'a [u8], &'a str)>,
}

/// 剥离 FLAC 文件头的 ID3v2 前缀（Netease 等来源的非规范残留）。
///
/// lofty 0.19 对「ID3v2 前缀 + FLAC」结构的写入有缺陷：前缀被解析时
/// 保存报 `File missing "fLaC" stream marker`；前缀未被解析时保存返回
/// Ok 但 Vorbis 内容被静默丢弃（实测空注释块）。因此先做字节级剥离，
/// 再交给 lofty 写入。优先按 ID3v2 头声明的 syncsafe 大小定位 fLaC，
/// 异常时退化为在文件头 1MB 窗口内扫描真实 fLaC 标记；两者都失败则
/// 不冒险剥离。返回是否实际剥除了前缀。
/// 若文件头带可剥离的 ID3v2 前缀，返回 `fLaC` 标记的字节偏移；否则 None。
/// 优先按 ID3v2 头声明的 syncsafe 大小定位，异常时退化为在文件头 1MB
/// 窗口内扫描真实标记（音频数据中出现该魔数的概率可忽略）。
fn flac_prefix_offset(data: &[u8]) -> Option<usize> {
    if data.len() < 14 || &data[..3] != b"ID3" {
        return None;
    }
    // ID3v2 头：'ID3' + 版本 2B + 标志 1B + syncsafe 大小 4B
    let declared = ((data[6] as u32) << 21)
        | ((data[7] as u32) << 14)
        | ((data[8] as u32) << 7)
        | (data[9] as u32);
    let declared_off = 10 + declared as usize;
    if declared_off + 4 <= data.len() && &data[declared_off..declared_off + 4] == b"fLaC" {
        return Some(declared_off);
    }
    let window = data.len().min(1024 * 1024);
    (10..window.saturating_sub(4)).find(|&i| &data[i..i + 4] == b"fLaC")
}

/// 供 metadata::enrich_file 判断内嵌封面是否可靠：带 ID3v2 前缀的 FLAC
/// 写标签时会剥离前缀，若封面只存在于前缀内则会被丢掉，应改用平台封面。
/// 非 ID3 前缀的文件立即返回 false，开销极小。
pub fn flac_has_id3v2_prefix(path: &Path) -> bool {
    use std::io::Read;
    let Ok(mut f) = std::fs::File::open(path) else {
        return false;
    };
    let mut head = [0u8; 14];
    if f.read_exact(&mut head).is_err() || &head[..3] != b"ID3" {
        return false;
    }
    let mut buf = Vec::with_capacity(1024 * 1024);
    buf.extend_from_slice(&head);
    let mut chunk = [0u8; 65536];
    while buf.len() < 1024 * 1024 {
        match f.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    }
    flac_prefix_offset(&buf).is_some()
}

fn strip_flac_id3v2_prefix(path: &Path) -> Result<bool, String> {
    let data = std::fs::read(path).map_err(|e| format!("读取失败: {e}"))?;
    let Some(offset) = flac_prefix_offset(&data) else {
        return Ok(false);
    };
    let mut tmp_name = path
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    tmp_name.push(".tagstrip.tmp");
    let tmp = PathBuf::from(path.with_file_name(tmp_name));
    std::fs::write(&tmp, &data[offset..]).map_err(|e| format!("写临时文件失败: {e}"))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("替换原文件失败: {e}"))?;
    Ok(true)
}

/// 给下载完成的文件写标签。全部字段为空时跳过；任何错误返回 Err（不阻断）。
pub fn write_tags(path: &Path, content: &TagContent) -> Result<(), String> {
    let title = content.title.trim();
    let artist = content.artist.trim();
    let album = content.album.trim();
    if title.is_empty()
        && artist.is_empty()
        && album.is_empty()
        && content.lyrics.is_none()
        && content.cover.is_none()
    {
        return Ok(());
    }

    // 先剥离 FLAC 头部的 ID3v2 前缀（见 strip_flac_id3v2_prefix 注释）
    if strip_flac_id3v2_prefix(path)? {
        log::debug!("已剥离 FLAC 头部 ID3v2 前缀: {}", path.display());
    }

    let mut tagged = Probe::open(path)
        .map_err(|e| format!("Probe 打开失败: {e}"))?
        .read()
        .map_err(|e| format!("解析标签失败: {e}"))?;

    // 兜底：剥离未能覆盖的残留 ID3v2（正常情况下剥离后文件已无前缀）
    if tagged.file_type() == FileType::Flac {
        let _ = tagged.remove(TagType::Id3v2);
    }

    // 取可写标签：主标签 → 首个标签 → 无标签则按文件类型新建槽位
    {
        let tag = if tagged.primary_tag_mut().is_some() {
            tagged.primary_tag_mut().unwrap()
        } else if tagged.first_tag_mut().is_some() {
            tagged.first_tag_mut().unwrap()
        } else {
            let tag_type = match tagged.file_type() {
                FileType::Flac => TagType::VorbisComments,
                _ => TagType::Id3v2,
            };
            tagged.insert_tag(Tag::new(tag_type));
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
        if let Some(lyrics) = content.lyrics {
            let lrc = lyrics.trim();
            if !lrc.is_empty() {
                tag.insert_text(ItemKey::Lyrics, lrc.to_string());
            }
        }
        if let Some((data, mime)) = content.cover {
            if !data.is_empty() {
                tag.remove_picture_type(PictureType::CoverFront);
                let picture = Picture::new_unchecked(
                    PictureType::CoverFront,
                    Some(MimeType::from_str(mime)),
                    None,
                    data.to_vec(),
                );
                tag.push_picture(picture);
            }
        }
    } // 结束 tag 借用

    tagged
        .save_to_path(path, WriteOptions::default())
        .map_err(|e| format!("写标签失败: {e}"))?;

    // 复查写入结果：lofty 在个别文件结构上会静默丢标签，读回确认并记录
    match Probe::open(path).map(|p| p.read()) {
        Ok(Ok(tf)) => match tf.primary_tag().or_else(|| tf.first_tag()) {
            Some(t) => log::debug!(
                "写标签复查: {} title={:?} artist={:?} album={:?} 歌词={} 封面={}",
                path.display(),
                t.title(),
                t.artist(),
                t.album(),
                t.get_string(&ItemKey::Lyrics).is_some(),
                t.pictures().len(),
            ),
            None => log::warn!("写标签复查: 未找到任何标签: {}", path.display()),
        },
        Ok(Err(e)) => log::warn!("写标签复查失败: {} {e}", path.display()),
        Err(e) => log::warn!("写标签复查失败: {} {e}", path.display()),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn syncsafe(n: u32) -> [u8; 4] {
        [
            ((n >> 21) & 0x7f) as u8,
            ((n >> 14) & 0x7f) as u8,
            ((n >> 7) & 0x7f) as u8,
            (n & 0x7f) as u8,
        ]
    }

    fn write_tmp(name: &str, data: &[u8]) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join("archoera-downloader-tag-tests");
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join(name);
        let mut f = std::fs::File::create(&p).unwrap();
        f.write_all(data).unwrap();
        p
    }

    #[test]
    fn strip_removes_valid_id3v2_prefix() {
        // 构造：合法 ID3v2.4 头（payload 1 字节）+ fLaC 标记
        let mut data = Vec::new();
        data.extend_from_slice(b"ID3");
        data.extend_from_slice(&[0x04, 0x00, 0x00]);
        data.extend_from_slice(&syncsafe(1));
        data.push(0x00);
        data.extend_from_slice(b"fLaC");
        data.extend_from_slice(&[0x00; 32]);
        let p = write_tmp("strip_ok.flac", &data);

        assert!(strip_flac_id3v2_prefix(&p).unwrap());
        let out = std::fs::read(&p).unwrap();
        assert_eq!(&out[..4], b"fLaC");
        assert!(!out.starts_with(b"ID3"));
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn strip_noop_without_prefix() {
        let mut data = Vec::new();
        data.extend_from_slice(b"fLaC");
        data.extend_from_slice(&[0x00; 32]);
        let p = write_tmp("strip_none.flac", &data);

        assert!(!strip_flac_id3v2_prefix(&p).unwrap());
        assert!(std::fs::read(&p).unwrap().starts_with(b"fLaC"));
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn strip_scans_fLaC_when_declared_size_bogus() {
        // 声明大小异常（110 字节）但窗口内能扫到真实 fLaC → 按实际偏移剥离
        let mut data = Vec::new();
        data.extend_from_slice(b"ID3");
        data.extend_from_slice(&[0x04, 0x00, 0x00]);
        data.extend_from_slice(&syncsafe(100));
        data.extend_from_slice(&[0xAA; 8]); // 实际 ID3 只有 8 字节
        data.extend_from_slice(b"fLaC");
        data.extend_from_slice(&[0x00; 16]);
        let p = write_tmp("strip_bogus.flac", &data);

        assert!(strip_flac_id3v2_prefix(&p).unwrap());
        assert!(std::fs::read(&p).unwrap().starts_with(b"fLaC"));
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn strip_skips_when_no_fLaC_in_window() {
        // 声明大小异常且窗口内找不到 fLaC → 不剥离、不破坏原文件
        let mut data = Vec::new();
        data.extend_from_slice(b"ID3");
        data.extend_from_slice(&[0x04, 0x00, 0x00]);
        data.extend_from_slice(&syncsafe(100));
        data.extend_from_slice(&[0xAA; 8]);
        data.extend_from_slice(&[0xBB; 32]); // 无 fLaC
        let p = write_tmp("strip_noflac.flac", &data);

        assert!(!strip_flac_id3v2_prefix(&p).unwrap());
        let out = std::fs::read(&p).unwrap();
        assert_eq!(&out[..3], b"ID3");
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn strip_short_file_noop() {
        let p = write_tmp("strip_short.flac", b"ID3\x04\x00\x00");
        assert!(!strip_flac_id3v2_prefix(&p).unwrap());
        let _ = std::fs::remove_file(&p);
    }

    /// 端到端：对「ID3v2 前缀 + FLAC」的真实下载文件走完整 write_tags，
    /// 断言标签真正写入 Vorbis（复现修复前的静默丢失场景）。
    /// 用法：TAG_TEST_FILE=/path/to/netease.flac cargo test e2e -- --ignored --nocapture
    #[test]
    #[ignore]
    fn e2e_write_tags_on_prefixed_flac() {
        let src = std::env::var("TAG_TEST_FILE").expect("需要 TAG_TEST_FILE");
        let p = PathBuf::from(src);
        let clean = std::fs::read(&p).unwrap();
        // 前置一个合法 ID3v2.4 头 + 空 payload，模拟 Netease 残留
        let mut data = Vec::new();
        data.extend_from_slice(b"ID3");
        data.extend_from_slice(&[0x04, 0x00, 0x00]);
        data.extend_from_slice(&syncsafe(1));
        data.push(0x00);
        data.extend_from_slice(&clean);
        let prefixed = write_tmp("e2e_prefixed.flac", &data);

        write_tags(
            &prefixed,
            &TagContent {
                title: "端到端标题",
                artist: "端到端歌手",
                album: "端到端专辑",
                lyrics: Some("[00:00.00]端到端歌词"),
                cover: None,
            },
        )
        .unwrap();

        let tagged = Probe::open(&prefixed).unwrap().read().unwrap();
        let t = tagged.primary_tag().or_else(|| tagged.first_tag()).unwrap();
        assert_eq!(t.title().as_deref(), Some("端到端标题"));
        assert_eq!(t.artist().as_deref(), Some("端到端歌手"));
        assert_eq!(t.album().as_deref(), Some("端到端专辑"));
        assert!(t.get_string(&ItemKey::Lyrics).is_some());
        eprintln!("端到端写标签成功: {:?}", t.title());
        let _ = std::fs::remove_file(&prefixed);
    }

    /// 端到端：对「真实 Netease FLAC」（fLaC 在 0 偏移、自带空 SEEKTABLE +
    /// Vorbis 注释、无封面）走完整 write_tags，断言标签与封面真正写入。
    /// 用法：TAG_TEST_FILE=/path/to/netease.flac cargo test e2e_real -- --ignored --nocapture
    #[test]
    #[ignore]
    fn e2e_write_tags_on_real_file() {
        let src = std::env::var("TAG_TEST_FILE").expect("需要 TAG_TEST_FILE");
        let clean = std::fs::read(&src).unwrap();
        let p = write_tmp("e2e_real.flac", &clean);
        // 1x1 红色 PNG
        let png: &[u8] = &[
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
            0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00,
            0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78,
            0x9C, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0xE5, 0x27, 0xD8, 0x0B, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ];

        write_tags(
            &p,
            &TagContent {
                title: "真实文件标题",
                artist: "真实文件歌手",
                album: "真实文件专辑",
                lyrics: Some("[00:00.00]真实文件歌词"),
                cover: Some((png, "image/png")),
            },
        )
        .unwrap();

        let tagged = Probe::open(&p).unwrap().read().unwrap();
        let t = tagged.primary_tag().or_else(|| tagged.first_tag()).unwrap();
        eprintln!(
            "真实文件复查: title={:?} artist={:?} album={:?} 歌词={} 封面={}",
            t.title(),
            t.artist(),
            t.album(),
            t.get_string(&ItemKey::Lyrics).is_some(),
            t.pictures().len(),
        );
        assert_eq!(t.title().as_deref(), Some("真实文件标题"));
        assert!(t.get_string(&ItemKey::Lyrics).is_some());
        assert!(!t.pictures().is_empty(), "封面必须写入");
        let _ = std::fs::remove_file(&p);
    }
}
