// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! QQMusic / 汽水 下载来源接入：`SourcePlatform` 新增变体的反序列化与
//! 回退协议兼容（Rust 侧无自研解析，解析失败后由 Dart 播放管线注入 URL）。

use archoera_downloader::models::{EnqueueRequest, SourcePlatform};

#[test]
fn qqmusic_and_soda_sources_deserialize() {
    let qq = r#"{
        "trackId": "97773",
        "source": "qqmusic",
        "platformId": "0039MnYb0qxYhV",
        "quality": "lossless",
        "title": "晴天",
        "artist": "周杰伦",
        "album": "叶惠美"
    }"#;
    let req: EnqueueRequest = serde_json::from_str(qq).expect("qqmusic 反序列化失败");
    assert_eq!(req.source, SourcePlatform::Qqmusic);
    assert_eq!(req.source.as_str(), "qqmusic");
    assert!(req.pre_resolved_url.is_none());

    let soda = r#"{
        "trackId": "7678897838486882344",
        "source": "soda",
        "platformId": "7678897838486882344",
        "quality": "lossless",
        "title": "晴天（杰伦）",
        "artist": "哇欣"
    }"#;
    let req: EnqueueRequest = serde_json::from_str(soda).expect("soda 反序列化失败");
    assert_eq!(req.source, SourcePlatform::Soda);
    assert_eq!(req.source.as_str(), "soda");
    assert!(req.pre_resolved_url.is_none());
}

#[test]
fn legacy_sources_still_parse() {
    let kg: EnqueueRequest = serde_json::from_str(
        r#"{"trackId":"a","source":"kugou","platformId":"h","quality":"hq","title":"t","artist":"a"}"#,
    )
    .unwrap();
    assert_eq!(kg.source, SourcePlatform::Kugou);
    let nt: EnqueueRequest = serde_json::from_str(
        r#"{"trackId":"b","source":"netease","platformId":"1","quality":"hq","title":"t","artist":"a"}"#,
    )
    .unwrap();
    assert_eq!(nt.source, SourcePlatform::Netease);
}
