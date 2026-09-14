// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! §12.1 下载回退协议单测：enqueue 请求新增 pre_resolved_* 字段的向后兼容
//! 反序列化、PreResolvedUrl 解析、以及历史持久化前的凭据剥离。

use archoera_downloader::models::{EnqueueRequest, PreResolvedUrl};

#[test]
fn enqueue_without_pre_resolved_is_backward_compatible() {
    // 旧 Dart 客户端不传 pre_resolved_* → 全部取默认（None / 空）。
    let json = r#"{
        "trackId": "t1",
        "source": "kugou",
        "platformId": "abc",
        "quality": "hq",
        "title": "晴天",
        "artist": "周杰伦",
        "album": "叶惠美",
        "extra": {"hashes": {"320k": "deadbeef"}, "sizes": {"320k": 123}}
    }"#;
    let req: EnqueueRequest = serde_json::from_str(json).expect("反序列化失败");
    assert!(req.pre_resolved_url.is_none());
    assert!(req.pre_resolved_quality_key.is_none());
    assert!(req.pre_resolved_ext.is_none());
    assert!(req.pre_resolved_size.is_none());
    assert!(req.pre_resolved_headers.is_empty());
}

#[test]
fn pre_resolved_url_parses_camel_case_headers() {
    let json = r#"{
        "url": "https://cdn.example/song.flac",
        "qualityKey": "flac",
        "fileExt": "flac",
        "size": 45678901,
        "headers": [["Referer", "https://music.163.com/"], ["Cookie", "MUSIC_U=xx"]]
    }"#;
    let pre: PreResolvedUrl = serde_json::from_str(json).expect("反序列化失败");
    assert_eq!(pre.url, "https://cdn.example/song.flac");
    assert_eq!(pre.quality_key.as_deref(), Some("flac"));
    assert_eq!(pre.file_ext.as_deref(), Some("flac"));
    assert_eq!(pre.size, Some(45678901));
    assert_eq!(pre.headers.len(), 2);
    assert_eq!(pre.headers[0].0, "Referer");
}

#[test]
fn without_pre_resolved_strips_url_and_credentials() {
    let json = r#"{
        "trackId": "t2",
        "source": "netease",
        "platformId": "186016",
        "quality": "lossless",
        "title": "晴天",
        "artist": "周杰伦",
        "preResolvedUrl": "https://cdn.example/song.flac",
        "preResolvedQualityKey": "flac",
        "preResolvedExt": "flac",
        "preResolvedSize": 999,
        "preResolvedHeaders": [["Cookie", "MUSIC_U=secret"]]
    }"#;
    let req: EnqueueRequest = serde_json::from_str(json).expect("反序列化失败");
    assert!(req.pre_resolved_url.is_some());

    let clean = req.clone().without_pre_resolved();
    assert!(clean.pre_resolved_url.is_none());
    assert!(clean.pre_resolved_quality_key.is_none());
    assert!(clean.pre_resolved_ext.is_none());
    assert!(clean.pre_resolved_size.is_none());
    assert!(clean.pre_resolved_headers.is_empty());

    // 剥离后序列化不含 URL / Cookie（历史落盘安全）
    let out = serde_json::to_string(&clean).unwrap();
    assert!(!out.contains("cdn.example"));
    assert!(!out.contains("MUSIC_U"));
    // 业务字段保留
    assert!(out.contains("\"platformId\":\"186016\""));
}
