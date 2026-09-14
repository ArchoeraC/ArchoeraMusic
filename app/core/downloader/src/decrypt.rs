// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later


use aes::cipher::{Block, BlockDecrypt, KeyInit};
#[cfg(test)]
use aes::cipher::BlockEncrypt;
use aes::Aes128;
use anyhow::{anyhow, bail, Result};
use base64::Engine as _;

const B64: base64::engine::general_purpose::GeneralPurpose =
    base64::engine::general_purpose::STANDARD;

fn aes128(key: &[u8]) -> Result<Aes128> {
    Aes128::new_from_slice(key).map_err(|e| anyhow!("invalid aes key: {e}"))
}

fn aes_ecb_decrypt(key: &[u8], data: &[u8]) -> Result<Vec<u8>> {
    if data.len() % 16 != 0 {
        bail!("invalid aes block size");
    }
    let cipher = aes128(key)?;
    let mut out = data.to_vec();
    for chunk in out.chunks_exact_mut(16) {
        cipher.decrypt_block(Block::<Aes128>::from_mut_slice(chunk));
    }
    Ok(out)
}

#[cfg(test)]
fn aes_ecb_encrypt(key: &[u8], data: &[u8]) -> Result<Vec<u8>> {
    if data.len() % 16 != 0 {
        bail!("invalid aes block size");
    }
    let cipher = aes128(key)?;
    let mut out = data.to_vec();
    for chunk in out.chunks_exact_mut(16) {
        cipher.encrypt_block(Block::<Aes128>::from_mut_slice(chunk));
    }
    Ok(out)
}

pub fn detect_audio_ext(data: &[u8]) -> &'static str {
    if data.len() >= 4 && &data[..4] == b"fLaC" {
        return "flac";
    }
    if data.len() >= 3 && &data[..3] == b"ID3" {
        return "mp3";
    }
    if data.len() >= 4 && &data[..4] == b"OggS" {
        return "ogg";
    }
    if data.len() >= 8 && &data[4..8] == b"ftyp" {
        return "m4a";
    }
    "mp3"
}


const NCM_CORE_KEY: &[u8] = b"hzHRAmso5kInbaxW";
const NCM_META_KEY: &[u8] = b"#14ljk_!\\]&0U<'(";

pub fn is_ncm(data: &[u8]) -> bool {
    data.len() >= 8 && &data[..8] == b"CTENFDAM"
}

fn read_u32_le(data: &[u8], off: usize) -> Option<u32> {
    data.get(off..off + 4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

fn pkcs7_unpad(data: Vec<u8>) -> Vec<u8> {
    if data.is_empty() {
        return data;
    }
    let pad = data[data.len() - 1] as usize;
    if pad == 0 || pad > data.len() {
        return data;
    }
    let n = data.len();
    for i in 0..pad {
        if data[n - 1 - i] != pad as u8 {
            return data;
        }
    }
    data[..n - pad].to_vec()
}

fn build_ncm_keybox(key: &[u8]) -> [u8; 256] {
    let mut box_ = [0u8; 256];
    for (i, b) in box_.iter_mut().enumerate() {
        *b = i as u8;
    }
    if key.is_empty() {
        return box_;
    }
    let mut c: usize;
    let mut last: usize = 0;
    let mut key_pos: usize = 0;
    for i in 0..256 {
        let swap = box_[i];
        c = (swap as usize + last + key[key_pos] as usize) & 0xff;
        box_[i] = box_[c];
        box_[c] = swap;
        last = c;
        key_pos += 1;
        if key_pos >= key.len() {
            key_pos = 0;
        }
    }
    box_
}

fn ncm_meta_value(meta: &[u8]) -> Option<serde_json::Value> {
    if meta.len() <= 22 {
        return None;
    }
    let decoded = B64.decode(&meta[22..]).ok()?;
    let dec = pkcs7_unpad(aes_ecb_decrypt(NCM_META_KEY, &decoded).ok()?);
    let s = String::from_utf8_lossy(&dec).to_string();
    let s = s.strip_prefix("music:").unwrap_or(&s);
    serde_json::from_str(s).ok()
}

fn parse_ncm_format(meta: &[u8]) -> String {
    ncm_meta_value(meta)
        .and_then(|v| v.get("format").and_then(|f| f.as_str()).map(String::from))
        .unwrap_or_default()
}

pub struct NcmMeta {
    pub format: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub cover: Option<(Vec<u8>, String)>,
}

fn parse_data_url(s: &str) -> Option<(Vec<u8>, String)> {
    let comma = s.find(',')?;
    let head = &s[..comma];
    let mime = head.strip_prefix("data:")?.split(';').next()?.to_string();
    let bytes = B64.decode(&s[comma + 1..]).ok()?;
    Some((bytes, mime))
}

pub fn ncm_metadata(data: &[u8]) -> Option<NcmMeta> {
    if !is_ncm(data) {
        return None;
    }
    let mut offset = 8usize + 2;
    let key_len = read_u32_le(data, offset)? as usize;
    offset += 4 + key_len;
    let meta_len = read_u32_le(data, offset)? as usize;
    let meta_start = offset + 4;
    if meta_start + meta_len > data.len() {
        return None;
    }
    let mut meta = data[meta_start..meta_start + meta_len].to_vec();
    for b in meta.iter_mut() {
        *b ^= 0x63;
    }
    let v = ncm_meta_value(&meta)?;
    let artist = v
        .get("artist")
        .and_then(|a| a.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|e| e.as_array().and_then(|p| p.first()).and_then(|n| n.as_str()))
                .collect::<Vec<_>>()
                .join(" / ")
        })
        .unwrap_or_default();
    Some(NcmMeta {
        format: v.get("format").and_then(|x| x.as_str()).unwrap_or_default().to_string(),
        title: v.get("musicName").and_then(|x| x.as_str()).unwrap_or_default().to_string(),
        artist,
        album: v.get("album").and_then(|x| x.as_str()).unwrap_or_default().to_string(),
        cover: v.get("albumPic").and_then(|x| x.as_str()).and_then(parse_data_url),
    })
}

pub fn is_qmc_ext(ext: &str) -> bool {
    matches!(
        ext.to_ascii_lowercase().as_str(),
        "qmc0"
            | "qmc3"
            | "qmcflac"
            | "qmcogg"
            | "bkcmp3"
            | "bkcflac"
            | "tkm"
            | "mflac"
            | "mgg"
            | "mgg1"
            | "mflac0"
            | "mgg0"
            | "mmp4"
    )
}

pub fn decrypt_container(
    data: &[u8],
    ext_hint: Option<&str>,
) -> Result<(Vec<u8>, String)> {
    if is_ncm(data) {
        return decrypt_ncm(data);
    }
    if ext_hint.map(is_qmc_ext).unwrap_or(false) {
        match crate::qmc::qmc_decrypt(data, &std::collections::HashMap::new()) {
            Ok(r) => return Ok(r),
            Err(e) => {
                if let Ok(r) = decrypt_qmc(data, ext_hint) {
                    return Ok(r);
                }
                return Err(e);
            }
        }
    }
    bail!("无法解析的头文件或行为");
}

pub fn decrypt_ncm(data: &[u8]) -> Result<(Vec<u8>, String)> {
    if !is_ncm(data) {
        bail!("invalid ncm file");
    }
    let mut offset = 8usize + 2;

    let key_len =
        read_u32_le(data, offset).ok_or_else(|| anyhow!("invalid ncm key length"))? as usize;
    let key_start = offset + 4;
    if key_start + key_len > data.len() {
        bail!("invalid ncm key length");
    }
    let mut key_data = data[key_start..key_start + key_len].to_vec();
    for b in key_data.iter_mut() {
        *b ^= 0x64;
    }
    offset = key_start + key_len;

    let mut decrypted_key = aes_ecb_decrypt(NCM_CORE_KEY, &key_data)?;
    decrypted_key = pkcs7_unpad(decrypted_key);
    if decrypted_key.len() > 17 {
        decrypted_key = decrypted_key[17..].to_vec();
    }
    if decrypted_key.is_empty() {
        bail!("invalid ncm key data");
    }
    let keybox = build_ncm_keybox(&decrypted_key);

    let meta_len =
        read_u32_le(data, offset).ok_or_else(|| anyhow!("invalid ncm meta length"))? as usize;
    let meta_start = offset + 4;
    if meta_start + meta_len > data.len() {
        bail!("invalid ncm meta length");
    }
    let mut meta_data = data[meta_start..meta_start + meta_len].to_vec();
    for b in meta_data.iter_mut() {
        *b ^= 0x63;
    }
    offset = meta_start + meta_len;
    let mut out_ext = parse_ncm_format(&meta_data);

    if offset + 9 > data.len() {
        bail!("invalid ncm payload");
    }
    offset += 9;

    let image_size =
        read_u32_le(data, offset).ok_or_else(|| anyhow!("invalid ncm image length"))? as usize;
    offset += 4 + image_size;
    if offset > data.len() {
        bail!("invalid ncm image block");
    }

    let mut audio = data[offset..].to_vec();
    for i in 0..audio.len() {
        let j = (i + 1) & 0xff;
        let idx = (keybox[j] as usize + keybox[(keybox[j] as usize + j) & 0xff] as usize) & 0xff;
        audio[i] ^= keybox[idx];
    }
    if out_ext.is_empty() {
        out_ext = detect_audio_ext(&audio).to_string();
    }
    Ok((audio, out_ext))
}


const QQ_MASK58: [u8; 56] = [
    74, 214, 202, 144, 103, 247, 82, 94, 149, 35, 159, 19, 17, 126, 71, 116, 61, 144, 170, 63, 81,
    198, 9, 213, 159, 250, 102, 249, 243, 214, 161, 144, 160, 247, 240, 29, 149, 222, 159, 132,
    17, 244, 14, 116, 187, 144, 188, 63, 146, 0, 9, 91, 159, 98, 102, 161,
];

const QQ_SUPER_A: u8 = 195;
const QQ_SUPER_B: u8 = 216;

struct QqMask {
    m128: [u8; 128],
}

impl QqMask {
    fn from_58(m58: &[u8; 56], a: u8, b: u8) -> Self {
        let mut out = [0u8; 128];
        let mut idx = 0usize;
        for i in 0..8 {
            out[idx] = a;
            idx += 1;
            out[idx..idx + 7].copy_from_slice(&m58[7 * i..7 * i + 7]);
            idx += 7;
            out[idx] = b;
            idx += 1;
            let rev = &m58[49 - 7 * i..56 - 7 * i];
            for j in (0..7).rev() {
                out[idx] = rev[j];
                idx += 1;
            }
        }
        Self { m128: out }
    }

    fn from_128(m128: &[u8; 128]) -> Option<Self> {
        let e = m128[0];
        let b = m128[8];
        for n in 0..8 {
            let i = 16 * n;
            let o = 120 - i;
            if m128[i] != e || m128[i + 8] != b {
                return None;
            }
            for j in 0..7 {
                if m128[i + 1 + j] != m128[o + 7 - j] {
                    return None;
                }
            }
        }
        Some(Self { m128: *m128 })
    }

    fn decrypt(&self, data: &[u8]) -> Vec<u8> {
        let mut out = data.to_vec();
        let mut r: isize = -1;
        let mut n: isize = -1;
        for byte in out.iter_mut() {
            r += 1;
            n += 1;
            if r == 32768 || (r > 32768 && (r + 1) % 32768 == 0) {
                r += 1;
                n += 1;
            }
            if n >= 128 {
                n -= 128;
            }
            *byte ^= self.m128[n as usize];
        }
        out
    }
}

fn detect_qq_mask(data: &[u8]) -> Option<QqMask> {
    let max = data.len().min(32768);
    let mut i = 0usize;
    while i + 128 <= max {
        if let Ok(arr) = <[u8; 128]>::try_from(&data[i..i + 128]) {
            if let Some(mask) = QqMask::from_128(&arr) {
                if mask.decrypt(&data[..4]) == b"fLaC" {
                    return Some(mask);
                }
            }
        }
        i += 128;
    }
    None
}

pub fn decrypt_qmc(data: &[u8], ext_hint: Option<&str>) -> Result<(Vec<u8>, String)> {
    if data.is_empty() {
        bail!("empty qmc input");
    }
    let mask = detect_qq_mask(data)
        .unwrap_or_else(|| QqMask::from_58(&QQ_MASK58, QQ_SUPER_A, QQ_SUPER_B));
    let plain = mask.decrypt(data);
    let ext = match ext_hint.map(|e| e.to_ascii_lowercase()) {
        Some(e) if matches!(e.as_str(), "mflac" | "qmcflac" | "bkcflac") => "flac".to_string(),
        Some(e) if matches!(e.as_str(), "mgg" | "qmcogg" | "mgg1" | "mgg0") => "ogg".to_string(),
        Some(e) if e == "tkm" || e == "mmp4" => "m4a".to_string(),
        _ => detect_audio_ext(&plain).to_string(),
    };
    Ok((plain, ext))
}



#[cfg(test)]
mod tests {
    use super::*;

    fn pkcs7_pad(mut data: Vec<u8>) -> Vec<u8> {
        let pad = 16 - (data.len() % 16);
        data.extend(std::iter::repeat(pad as u8).take(pad));
        data
    }

    fn build_ncm(audio: &[u8], ext: &str) -> Vec<u8> {
        build_ncm_raw(audio, &format!("{{\"format\":\"{ext}\"}}"))
    }

    fn build_ncm_raw(audio: &[u8], meta_json: &str) -> Vec<u8> {
        let audio_key: Vec<u8> = (0u8..16).map(|i| i.wrapping_mul(7).wrapping_add(3)).collect();
        let keybox = build_ncm_keybox(&audio_key);
        let mut enc = audio.to_vec();
        for i in 0..enc.len() {
            let j = (i + 1) & 0xff;
            let idx =
                (keybox[j] as usize + keybox[(keybox[j] as usize + j) & 0xff] as usize) & 0xff;
            enc[i] ^= keybox[idx];
        }
        let mut key_plain = b"neteasecloudmusic".to_vec();
        key_plain.extend_from_slice(&audio_key);
        let mut key_data = aes_ecb_encrypt(NCM_CORE_KEY, &pkcs7_pad(key_plain)).unwrap();
        for b in key_data.iter_mut() {
            *b ^= 0x64;
        }
        let meta_text = format!("music:{meta_json}");
        let enc_meta = aes_ecb_encrypt(NCM_META_KEY, &pkcs7_pad(meta_text.into_bytes())).unwrap();
        let mut meta = vec![0u8; 22];
        meta.extend_from_slice(B64.encode(enc_meta).as_bytes());
        for b in meta.iter_mut() {
            *b ^= 0x63;
        }
        let mut out = Vec::new();
        out.extend_from_slice(b"CTENFDAM");
        out.extend_from_slice(&[0, 0]);
        out.extend_from_slice(&(key_data.len() as u32).to_le_bytes());
        out.extend_from_slice(&key_data);
        out.extend_from_slice(&(meta.len() as u32).to_le_bytes());
        out.extend_from_slice(&meta);
        out.extend_from_slice(&[0u8; 9]);
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(&enc);
        out
    }

    #[test]
    fn ncm_roundtrip() {
        let audio: Vec<u8> = (0u32..500).map(|i| (i.wrapping_mul(31)) as u8).collect();
        let ncm = build_ncm(&audio, "flac");
        assert!(is_ncm(&ncm));
        let (plain, ext) = decrypt_ncm(&ncm).unwrap();
        assert_eq!(plain, audio);
        assert_eq!(ext, "flac");
    }

    #[test]
    fn qmc_roundtrip() {
        let mask = QqMask::from_58(&QQ_MASK58, QQ_SUPER_A, QQ_SUPER_B);
        let mut plain = b"fLaC".to_vec();
        plain.extend((0u32..1000).map(|i| (i.wrapping_mul(13)) as u8));
        let enc = mask.decrypt(&plain);
        assert_ne!(enc, plain);
        let (dec, ext) = decrypt_qmc(&enc, Some("mflac")).unwrap();
        assert_eq!(dec, plain);
        assert_eq!(ext, "flac");
    }

    #[test]
    fn ncm_metadata_extract() {        let meta = r#"{"format":"flac","musicName":"晴天","album":"叶惠美","artist":[["周杰伦",4558]],"albumPic":"data:image/png;base64,AQID"}"#;
        let audio: Vec<u8> = (0u32..64).map(|i| i as u8).collect();
        let ncm = build_ncm_raw(&audio, meta);
        let m = ncm_metadata(&ncm).unwrap();
        assert_eq!(m.format, "flac");
        assert_eq!(m.title, "晴天");
        assert_eq!(m.artist, "周杰伦");
        assert_eq!(m.album, "叶惠美");
        let (cover, mime) = m.cover.unwrap();
        assert_eq!(mime, "image/png");
        assert_eq!(cover, vec![1, 2, 3]);
    }

    #[test]
    fn decrypt_container_dispatch() {
        let audio: Vec<u8> = (0u32..128).map(|i| (i * 5) as u8).collect();
        let ncm = build_ncm(&audio, "mp3");
        let (plain, ext) = decrypt_container(&ncm, Some("ncm")).unwrap();
        assert_eq!(plain, audio);
        assert_eq!(ext, "mp3");

        let mask = QqMask::from_58(&QQ_MASK58, QQ_SUPER_A, QQ_SUPER_B);
        let mut qplain = b"fLaC".to_vec();
        qplain.extend((0u32..200).map(|i| i as u8));
        let qenc = mask.decrypt(&qplain);
        let (qdec, qext) = decrypt_container(&qenc, Some("mflac")).unwrap();
        assert_eq!(qdec, qplain);
        assert_eq!(qext, "flac");

        assert!(decrypt_container(b"not encrypted", Some("mp3")).is_err());
    }
}
