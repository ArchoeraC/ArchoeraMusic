// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later


use aes::cipher::{Block, BlockDecrypt, BlockEncrypt, KeyInit};
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
    play_auth: Option<&str>,
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
    if is_cenc(data) {
        let auth = play_auth.ok_or_else(|| anyhow!("执行部分操作时发生错误"))?;
        let plain = decrypt_cenc(data, auth)?;
        let ext = detect_audio_ext(&plain).to_string();
        return Ok((plain, ext));
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


fn bitcount(n: usize) -> u32 {
    let mut u = n as u32;
    u = u.wrapping_sub((u >> 1) & 0x5555_5555);
    u = (u & 0x3333_3333).wrapping_add((u >> 2) & 0x3333_3333);
    (((u.wrapping_add(u >> 4)) & 0x0f0f_0f0f).wrapping_mul(0x0101_0101) >> 24) & 0xff
}

fn decode_base36(c: u8) -> i32 {
    if c.is_ascii_digit() {
        (c - b'0') as i32
    } else if (b'a'..=b'z').contains(&c) {
        (c - b'a') as i32 + 10
    } else {
        0xff
    }
}

fn decrypt_spade_inner(key: &[u8]) -> Vec<u8> {
    let mut buff = vec![0xfa, 0x55];
    buff.extend_from_slice(key);
    let mut result = vec![0u8; key.len()];
    for i in 0..key.len() {
        let mut v = (key[i] ^ buff[i]) as i32 - bitcount(i) as i32 - 21;
        while v < 0 {
            v += 255;
        }
        result[i] = v as u8;
    }
    result
}

fn extract_cenc_key(play_auth: &str) -> Result<Vec<u8>> {
    let bytes = B64
        .decode(play_auth.trim())
        .map_err(|e| anyhow!("auth base64: {e}"))?;
    if bytes.len() < 3 {
        bail!("auth data too short");
    }
    let padding_len = ((bytes[0] ^ bytes[1] ^ bytes[2]) as i32 - 48).max(0) as usize;
    if bytes.len() < padding_len + 2 {
        bail!("invalid padding length");
    }
    let inner = &bytes[1..bytes.len() - padding_len];
    let tmp = decrypt_spade_inner(inner);
    if tmp.is_empty() {
        bail!("decryption failed");
    }
    let skip = decode_base36(tmp[0]);
    if skip < 0 {
        bail!("invalid skip byte");
    }
    let end = 1 + (bytes.len() - padding_len - 2) - skip as usize;
    if end > tmp.len() || end < 1 {
        bail!("index out of bounds");
    }
    let hex_key = String::from_utf8_lossy(&tmp[1..end]).to_string();
    hex::decode(hex_key.trim()).map_err(|e| anyhow!("hex key: {e}"))
}

struct CtrStream {
    cipher: Aes128,
    counter: [u8; 16],
    ks: [u8; 16],
    pos: usize,
}

impl CtrStream {
    fn new(cipher: &Aes128, iv: &[u8]) -> Self {
        let mut counter = [0u8; 16];
        let n = iv.len().min(16);
        counter[..n].copy_from_slice(&iv[..n]);
        Self {
            cipher: cipher.clone(),
            counter,
            ks: [0u8; 16],
            pos: 16,
        }
    }

    fn refill(&mut self) {
        let mut blk = Block::<Aes128>::clone_from_slice(&self.counter);
        self.cipher.encrypt_block(&mut blk);
        self.ks.copy_from_slice(&blk);
        for i in (0..16).rev() {
            self.counter[i] = self.counter[i].wrapping_add(1);
            if self.counter[i] != 0 {
                break;
            }
        }
        self.pos = 0;
    }

    fn xor(&mut self, data: &mut [u8]) {
        for b in data.iter_mut() {
            if self.pos == 16 {
                self.refill();
            }
            *b ^= self.ks[self.pos];
            self.pos += 1;
        }
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    (0..=haystack.len() - needle.len()).find(|&i| &haystack[i..i + needle.len()] == needle)
}

struct Mp4Box {
    size: usize,
    data_start: usize,
    data_end: usize,
}

fn be_u32(data: &[u8], pos: usize) -> usize {
    u32::from_be_bytes([data[pos], data[pos + 1], data[pos + 2], data[pos + 3]]) as usize
}

fn find_box(data: &[u8], box_type: &[u8; 4], start: usize, end: usize) -> Option<Mp4Box> {
    let end = end.min(data.len());
    let mut pos = start;
    while pos + 8 <= end {
        let size = be_u32(data, pos);
        if size < 8 || pos + size > data.len() {
            break;
        }
        if &data[pos + 4..pos + 8] == box_type {
            return Some(Mp4Box {
                size,
                data_start: pos + 8,
                data_end: pos + size,
            });
        }
        pos += size;
    }
    None
}

fn box_child_start(box_type: &[u8], offset: usize, header: usize) -> Option<usize> {
    match box_type {
        b"moov" | b"trak" | b"mdia" | b"minf" | b"stbl" | b"sinf" | b"schi" => {
            Some(offset + header)
        }
        b"stsd" => Some(offset + header + 8),
        b"enca" | b"mp4a" | b"alac" | b"fLaC" => Some(offset + header + 28),
        _ => None,
    }
}

fn find_box_deep(data: &[u8], box_type: &[u8; 4], start: usize, end: usize) -> Option<Mp4Box> {
    let end = end.min(data.len());
    let mut pos = start;
    while pos + 8 <= end {
        let mut size = be_u32(data, pos);
        let mut header = 8usize;
        if size == 1 {
            if pos + 16 > end {
                break;
            }
            let s64 = u64::from_be_bytes([
                data[pos + 8],
                data[pos + 9],
                data[pos + 10],
                data[pos + 11],
                data[pos + 12],
                data[pos + 13],
                data[pos + 14],
                data[pos + 15],
            ]) as usize;
            if s64 > end - pos {
                break;
            }
            size = s64;
            header = 16;
        }
        if size < header || pos + size > end {
            break;
        }
        let cur = &data[pos + 4..pos + 8];
        if cur == box_type {
            return Some(Mp4Box {
                size,
                data_start: pos + header,
                data_end: pos + size,
            });
        }
        if let Some(child_start) = box_child_start(cur, pos, header) {
            if child_start < pos + size {
                if let Some(found) = find_box_deep(data, box_type, child_start, pos + size) {
                    return Some(found);
                }
            }
        }
        pos += size;
    }
    None
}

fn parse_stsz(data: &[u8]) -> Vec<u32> {
    if data.len() < 12 {
        return Vec::new();
    }
    let fixed = be_u32(data, 4) as u32;
    let count = be_u32(data, 8);
    let mut sizes = vec![0u32; count];
    if fixed != 0 {
        for s in sizes.iter_mut() {
            *s = fixed;
        }
    } else {
        for (i, s) in sizes.iter_mut().enumerate() {
            let off = 12 + i * 4;
            if off + 4 <= data.len() {
                *s = be_u32(data, off) as u32;
            }
        }
    }
    sizes
}

#[derive(Clone)]
struct SencSample {
    iv: Vec<u8>,
    subsamples: Vec<(u16, u32)>,
}

fn parse_senc(data: &[u8], iv_size: usize) -> Vec<SencSample> {
    if data.len() < 8 {
        return Vec::new();
    }
    let iv_size = if iv_size == 8 || iv_size == 16 { iv_size } else { 8 };
    let flags = (be_u32(data, 0) as u32) & 0x00ff_ffff;
    let count = be_u32(data, 4);
    let mut samples = Vec::with_capacity(count);
    let mut ptr = 8usize;
    let has_sub = (flags & 0x02) != 0;
    for _ in 0..count {
        if ptr + iv_size > data.len() {
            break;
        }
        let iv = data[ptr..ptr + iv_size].to_vec();
        ptr += iv_size;
        let mut subs = Vec::new();
        if has_sub {
            if ptr + 2 > data.len() {
                break;
            }
            let sub_count = u16::from_be_bytes([data[ptr], data[ptr + 1]]) as usize;
            ptr += 2;
            if ptr + sub_count * 6 > data.len() {
                break;
            }
            for _ in 0..sub_count {
                let clear = u16::from_be_bytes([data[ptr], data[ptr + 1]]);
                let encrypted =
                    u32::from_be_bytes([data[ptr + 2], data[ptr + 3], data[ptr + 4], data[ptr + 5]]);
                subs.push((clear, encrypted));
                ptr += 6;
            }
        }
        samples.push(SencSample { iv, subsamples: subs });
    }
    samples
}

fn default_per_sample_iv_size(data: &[u8], start: usize, end: usize) -> usize {
    match find_box_deep(data, b"tenc", start, end) {
        Some(t) if t.data_end - t.data_start >= 8 => {
            let iv = data[t.data_start + 7] as usize;
            if iv == 8 || iv == 16 {
                iv
            } else {
                8
            }
        }
        _ => 8,
    }
}

fn encrypted_sample_original_format(stsd: &[u8]) -> [u8; 4] {
    if let Some(idx) = find_subslice(stsd, b"frma") {
        if idx < 4 || idx + 8 > stsd.len() {
            return *b"mp4a";
        }
        let size = be_u32(stsd, idx - 4);
        if size < 12 || idx - 4 + size > stsd.len() {
            return *b"mp4a";
        }
        return [stsd[idx + 4], stsd[idx + 5], stsd[idx + 6], stsd[idx + 7]];
    }
    *b"mp4a"
}

fn decrypt_senc_sample(
    cipher: &Aes128,
    chunk: &[u8],
    sample: &SencSample,
) -> Result<Vec<u8>> {
    let mut stream = CtrStream::new(cipher, &sample.iv);
    let mut dst = vec![0u8; chunk.len()];
    if sample.subsamples.is_empty() {
        dst.copy_from_slice(chunk);
        stream.xor(&mut dst);
        return Ok(dst);
    }
    let mut pos = 0usize;
    for (clear, encrypted) in &sample.subsamples {
        let mut clear = *clear as usize;
        if clear > chunk.len() - pos {
            clear = chunk.len() - pos;
        }
        dst[pos..pos + clear].copy_from_slice(&chunk[pos..pos + clear]);
        pos += clear;
        if pos >= chunk.len() {
            break;
        }
        let mut enc = *encrypted as usize;
        if enc > chunk.len() - pos {
            enc = chunk.len() - pos;
        }
        dst[pos..pos + enc].copy_from_slice(&chunk[pos..pos + enc]);
        stream.xor(&mut dst[pos..pos + enc]);
        pos += enc;
        if pos >= chunk.len() {
            break;
        }
    }
    if pos < chunk.len() {
        dst[pos..].copy_from_slice(&chunk[pos..]);
    }
    Ok(dst)
}

pub fn is_cenc(data: &[u8]) -> bool {
    data.len() >= 8
        && &data[4..8] == b"ftyp"
        && find_subslice(&data[..data.len().min(4 * 1024 * 1024)], b"senc").is_some()
}

pub fn decrypt_cenc(data: &[u8], play_auth: &str) -> Result<Vec<u8>> {
    let key = extract_cenc_key(play_auth)?;
    if key.len() != 16 {
        bail!("unexpected cenc key length {}", key.len());
    }

    let moov =
        find_box(data, b"moov", 0, data.len()).ok_or_else(|| anyhow!("moov box not found"))?;
    let stbl = find_box(data, b"stbl", moov.data_start, moov.data_end)
        .or_else(|| {
            let trak = find_box(data, b"trak", moov.data_start, moov.data_end)?;
            let mdia = find_box(data, b"mdia", trak.data_start, trak.data_end)?;
            let minf = find_box(data, b"minf", mdia.data_start, mdia.data_end)?;
            find_box(data, b"stbl", minf.data_start, minf.data_end)
        })
        .ok_or_else(|| anyhow!("stbl box not found"))?;

    let stsz = find_box(data, b"stsz", stbl.data_start, stbl.data_end)
        .ok_or_else(|| anyhow!("stsz box not found"))?;
    let sample_sizes = parse_stsz(&data[stsz.data_start..stsz.data_end]);

    let senc = find_box(data, b"senc", moov.data_start, moov.data_end)
        .or_else(|| find_box(data, b"senc", stbl.data_start, stbl.data_end))
        .ok_or_else(|| anyhow!("senc box not found"))?;
    let iv_size = default_per_sample_iv_size(data, stbl.data_start, stbl.data_end);
    let senc_samples = parse_senc(&data[senc.data_start..senc.data_end], iv_size);

    let mdat =
        find_box(data, b"mdat", 0, data.len()).ok_or_else(|| anyhow!("mdat box not found"))?;

    let cipher = aes128(&key)?;

    let mut out = data.to_vec();
    let mut read_ptr = mdat.data_start;
    let mut decrypted_mdat = Vec::with_capacity(mdat.size.saturating_sub(8));
    for (i, size) in sample_sizes.iter().enumerate() {
        let size = *size as usize;
        if read_ptr + size > out.len() {
            break;
        }
        if i < senc_samples.len() {
            let dst =
                decrypt_senc_sample(&cipher, &out[read_ptr..read_ptr + size], &senc_samples[i])?;
            decrypted_mdat.extend_from_slice(&dst);
        } else {
            decrypted_mdat.extend_from_slice(&out[read_ptr..read_ptr + size]);
        }
        read_ptr += size;
    }
    if decrypted_mdat.len() != mdat.size.saturating_sub(8) {
        bail!("decrypted size mismatch");
    }
    out[mdat.data_start..mdat.data_start + decrypted_mdat.len()].copy_from_slice(&decrypted_mdat);

    if let Some(stsd) = find_box(data, b"stsd", stbl.data_start, stbl.data_end) {
        let slice = out[stsd.data_start..stsd.data_end].to_vec();
        if let Some(idx) = find_subslice(&slice, b"enca") {
            let orig = encrypted_sample_original_format(&slice);
            let mut buf = slice;
            buf[idx..idx + 4].copy_from_slice(&orig);
            out[stsd.data_start..stsd.data_end].copy_from_slice(&buf);
        }
    }
    Ok(out)
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

    fn invert_spade(result: &[u8]) -> Vec<u8> {
        let mut k = vec![0u8; result.len()];
        for i in 0..result.len() {
            let buff = if i == 0 {
                0xFA
            } else if i == 1 {
                0x55
            } else {
                k[i - 2]
            };
            let v = ((result[i] as i32 + bitcount(i) as i32 + 21) % 255) as u8;
            k[i] = v ^ buff;
        }
        k
    }

    #[test]
    fn cenc_key_extraction_roundtrip() {
        let hex_key = "00112233445566778899aabbccddeeff";
        let mut tmp = vec![b'2'];
        tmp.extend_from_slice(hex_key.as_bytes());
        tmp.extend_from_slice(&[0, 0]);
        let inner = invert_spade(&tmp);
        let p0 = inner[0] ^ inner[1] ^ 48;
        let mut bytes = vec![p0];
        bytes.extend_from_slice(&inner);
        let play_auth = B64.encode(&bytes);
        let key = extract_cenc_key(&play_auth).unwrap();
        assert_eq!(hex::encode(key), hex_key);
    }

    fn bx(t: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut v = Vec::with_capacity(8 + payload.len());
        v.extend_from_slice(&((8 + payload.len()) as u32).to_be_bytes());
        v.extend_from_slice(t);
        v.extend_from_slice(payload);
        v
    }

    #[test]
    fn cenc_full_roundtrip() {
        let hex_key = "00112233445566778899aabbccddeeff";
        let mut tmp = vec![b'2'];
        tmp.extend_from_slice(hex_key.as_bytes());
        tmp.extend_from_slice(&[0, 0]);
        let inner = invert_spade(&tmp);
        let p0 = inner[0] ^ inner[1] ^ 48;
        let mut auth_bytes = vec![p0];
        auth_bytes.extend_from_slice(&inner);
        let play_auth = B64.encode(&auth_bytes);
        let key = hex::decode(hex_key).unwrap();

        let samples: Vec<Vec<u8>> = vec![
            (0u8..64).map(|i| i.wrapping_mul(3)).collect(),
            (0u8..32).map(|i| i.wrapping_add(200)).collect(),
        ];
        let ivs: Vec<[u8; 8]> = vec![[1, 2, 3, 4, 5, 6, 7, 8], [9, 10, 11, 12, 13, 14, 15, 16]];
        let cipher = aes128(&key).unwrap();
        let mut mdat_payload = Vec::new();
        for (s, iv) in samples.iter().zip(ivs.iter()) {
            let mut buf = s.clone();
            CtrStream::new(&cipher, iv).xor(&mut buf);
            mdat_payload.extend_from_slice(&buf);
        }

        let mut stsz = vec![0u8; 8];
        stsz.extend_from_slice(&(samples.len() as u32).to_be_bytes());
        for s in &samples {
            stsz.extend_from_slice(&(s.len() as u32).to_be_bytes());
        }
        let mut senc = vec![0u8; 4];
        senc.extend_from_slice(&(samples.len() as u32).to_be_bytes());
        for iv in &ivs {
            senc.extend_from_slice(iv);
        }
        let mut tenc = vec![0u8, 0, 0, 0, 0, 0, 8];
        tenc.extend_from_slice(&[0u8; 16]);
        let mut enca_payload = vec![0u8; 28];
        enca_payload.extend_from_slice(&bx(b"frma", b"mp4a"));
        let sample_entry = bx(b"enca", &enca_payload);
        let mut stsd_payload = vec![0u8; 4];
        stsd_payload.extend_from_slice(&1u32.to_be_bytes());
        stsd_payload.extend_from_slice(&sample_entry);

        let stbl = bx(
            b"stbl",
            &[
                bx(b"stsd", &stsd_payload),
                bx(b"stsz", &stsz),
                bx(b"senc", &senc),
                bx(b"sinf", &bx(b"schi", &bx(b"tenc", &tenc))),
            ]
            .concat(),
        );
        let minf = bx(b"minf", &stbl);
        let mdia = bx(b"mdia", &minf);
        let trak = bx(b"trak", &mdia);
        let moov = bx(b"moov", &trak);
        let ftyp = bx(b"ftyp", b"isom\x00\x00\x02\x00isom");
        let mdat = bx(b"mdat", &mdat_payload);

        let mut file = Vec::new();
        file.extend_from_slice(&ftyp);
        file.extend_from_slice(&moov);
        let mdat_start = file.len() + 8;
        file.extend_from_slice(&mdat);

        assert!(is_cenc(&file));
        let dec = decrypt_cenc(&file, &play_auth).unwrap();

        let want: Vec<u8> = samples.concat();
        assert_eq!(&dec[mdat_start..mdat_start + want.len()], want.as_slice());
        assert!(find_subslice(&dec, b"enca").is_none());
        assert!(find_subslice(&dec, b"mp4a").is_some());
    }

    #[test]
    fn ncm_metadata_extract() {
        let meta = r#"{"format":"flac","musicName":"晴天","album":"叶惠美","artist":[["周杰伦",4558]],"albumPic":"data:image/png;base64,AQID"}"#;
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
        let (plain, ext) = decrypt_container(&ncm, Some("ncm"), None).unwrap();
        assert_eq!(plain, audio);
        assert_eq!(ext, "mp3");

        let mask = QqMask::from_58(&QQ_MASK58, QQ_SUPER_A, QQ_SUPER_B);
        let mut qplain = b"fLaC".to_vec();
        qplain.extend((0u32..200).map(|i| i as u8));
        let qenc = mask.decrypt(&qplain);
        let (qdec, qext) = decrypt_container(&qenc, Some("mflac"), None).unwrap();
        assert_eq!(qdec, qplain);
        assert_eq!(qext, "flac");

        assert!(decrypt_container(b"not encrypted", Some("mp3"), None).is_err());
    }
}
