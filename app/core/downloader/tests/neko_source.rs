// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 实验性第三方音源 NekoMusic 的下载来源接入：`SourcePlatform::Neko` 变体的
//! 反序列化（`source:"neko"` 必须能入队），以及回退协议兼容（Rust 无自研解析，
//! 解析失败后由 Dart 播放管线注入预解析 URL）。

use archoera_downloader::models::{EnqueueRequest, SourcePlatform};

#[test]
fn neko_source_deserializes() {
    let neko = r#"{
        "trackId": "13751",
        "source": "neko",
        "platformId": "13751",
        "quality": "hq",
        "title": "天使ロード中",
        "artist": "三Z-STUDIO",
        "album": "绝区零"
    }"#;
    let req: EnqueueRequest = serde_json::from_str(neko).expect("neko 反序列化失败");
    assert_eq!(req.source, SourcePlatform::Neko);
    assert_eq!(req.source.as_str(), "neko");
    assert!(req.pre_resolved_url.is_none());
}

#[test]
fn neko_enqueue_lyrics_parses() {
    // Dart 侧「强制重写歌词」注入的标准 LRC 必须能被解析（顶层 `lyrics` 字段）。
    let neko = r#"{
        "trackId": "33814",
        "source": "neko",
        "platformId": "33814",
        "quality": "hq",
        "title": "三拜红尘凉",
        "artist": "尹昔眠",
        "album": "三拜红尘凉",
        "lyrics": "[00:01.00]标准歌词\n[00:03.00]第二句"
    }"#;
    let req: EnqueueRequest = serde_json::from_str(neko).expect("neko(lyrics) 反序列化失败");
    assert_eq!(req.source, SourcePlatform::Neko);
    assert_eq!(req.lyrics.as_deref(), Some("[00:01.00]标准歌词\n[00:03.00]第二句"));
}

#[test]
fn enqueue_without_lyrics_is_backward_compatible() {
    let kg: EnqueueRequest = serde_json::from_str(
        r#"{"trackId":"a","source":"kugou","platformId":"h","quality":"hq","title":"t","artist":"a"}"#,
    )
    .unwrap();
    assert!(kg.lyrics.is_none());
}

#[test]
fn neko_pre_resolved_fallback_parses() {
    // Dart 回退路径注入的 camelCase 预解析 JSON 必须可解析。
    let pre = r#"{
        "url": "https://music.cnmsb.xin/api/music/file/13751",
        "qualityKey": "320k",
        "fileExt": "flac",
        "headers": [["Referer", "https://music.cnmsb.xin"]]
    }"#;
    let parsed: archoera_downloader::models::PreResolvedUrl =
        serde_json::from_str(pre).expect("neko 预解析反序列化失败");
    assert_eq!(parsed.file_ext.as_deref(), Some("flac"));
    assert_eq!(parsed.headers.len(), 1);
}
