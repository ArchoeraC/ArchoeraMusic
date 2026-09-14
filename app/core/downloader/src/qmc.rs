// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later


use std::collections::HashMap;

use anyhow::{anyhow, bail, Result};
use base64::Engine as _;

const B64: base64::engine::general_purpose::GeneralPurpose =
    base64::engine::general_purpose::STANDARD;

const RAW_KEY_PREFIX_V2: &[u8] = b"QQMusic EncV2,Key:";


const TEA_DELTA: u32 = 0x9E37_79B9;

fn read_u32_be(data: &[u8], off: usize) -> u32 {
    u32::from_be_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]])
}

#[allow(clippy::many_single_char_names)]
fn tea_decrypt_words(v0: &mut u32, v1: &mut u32, k: &[u32; 4]) {
    let cycles: u32 = 16;
    let mut sum = TEA_DELTA.wrapping_mul(cycles);
    for _ in 0..cycles {
        *v1 = v1.wrapping_sub(
            ((*v0 << 4).wrapping_add(k[2]))
                ^ (v0.wrapping_add(sum))
                ^ ((*v0 >> 5).wrapping_add(k[3])),
        );
        *v0 = v0.wrapping_sub(
            ((*v1 << 4).wrapping_add(k[0]))
                ^ (v1.wrapping_add(sum))
                ^ ((*v1 >> 5).wrapping_add(k[1])),
        );
        sum = sum.wrapping_sub(TEA_DELTA);
    }
}

struct TeaCbc {
    dest: [u8; 8],
    iv_prev: [u8; 8],
    iv_cur: [u8; 8],
    pos: usize,
    dest_idx: usize,
    key: [u32; 4],
}

impl TeaCbc {
    fn crypt_block(&mut self, in_buf: &[u8]) {
        self.iv_prev = self.iv_cur;
        self.iv_cur.copy_from_slice(&in_buf[self.pos..self.pos + 8]);
        for i in 0..8 {
            self.dest[i] ^= self.iv_cur[i];
        }
        let mut v0 = read_u32_be(&self.dest, 0);
        let mut v1 = read_u32_be(&self.dest, 4);
        tea_decrypt_words(&mut v0, &mut v1, &self.key);
        self.dest[..4].copy_from_slice(&v0.to_be_bytes());
        self.dest[4..].copy_from_slice(&v1.to_be_bytes());
        self.pos += 8;
        self.dest_idx = 0;
    }
}

fn decrypt_tencent_tea(in_buf: &[u8], key: &[u8]) -> Result<Vec<u8>> {
    if in_buf.len() % 8 != 0 {
        bail!("inBuf size not a multiple of the block size");
    }
    if in_buf.len() < 16 {
        bail!("inBuf size too small");
    }
    let kw = [
        read_u32_be(key, 0),
        read_u32_be(key, 4),
        read_u32_be(key, 8),
        read_u32_be(key, 12),
    ];

    let mut first = [0u8; 8];
    {
        let mut v0 = read_u32_be(in_buf, 0);
        let mut v1 = read_u32_be(in_buf, 4);
        tea_decrypt_words(&mut v0, &mut v1, &kw);
        first[..4].copy_from_slice(&v0.to_be_bytes());
        first[4..].copy_from_slice(&v1.to_be_bytes());
    }
    let pad_len = (first[0] & 0x7) as usize;
    let out_len = in_buf.len() - 1 - pad_len - 2 - 7;
    if out_len > in_buf.len() {
        bail!("invalid tea output length");
    }
    let mut out = vec![0u8; out_len];
    let mut st = TeaCbc {
        dest: first,
        iv_prev: [0u8; 8],
        iv_cur: in_buf[..8].try_into().unwrap(),
        pos: 8,
        dest_idx: 1 + pad_len,
        key: kw,
    };

    let mut i = 1;
    while i <= 2 {
        if st.dest_idx < 8 {
            st.dest_idx += 1;
            i += 1;
        } else if st.dest_idx == 8 {
            st.crypt_block(in_buf);
        }
    }

    let mut out_pos = 0;
    while out_pos < out_len {
        if st.dest_idx < 8 {
            out[out_pos] = st.dest[st.dest_idx] ^ st.iv_prev[st.dest_idx];
            st.dest_idx += 1;
            out_pos += 1;
        } else if st.dest_idx == 8 {
            st.crypt_block(in_buf);
        }
    }

    for _ in 0..7 {
        if st.dest[st.dest_idx] != st.iv_prev[st.dest_idx] {
            bail!("zero check failed");
        }
    }
    Ok(out)
}


fn simple_make_key(salt: u8, len: usize) -> Vec<u8> {
    (0..len)
        .map(|i| ((salt as f64 + i as f64 * 0.1).tan().abs() * 100.0) as u8)
        .collect()
}

const DERIVE_V2_KEY1: [u8; 16] = [
    0x33, 0x38, 0x36, 0x5A, 0x4A, 0x59, 0x21, 0x40, 0x23, 0x2A, 0x24, 0x25, 0x5E, 0x26, 0x29,
    0x28,
];
const DERIVE_V2_KEY2: [u8; 16] = [
    0x2A, 0x2A, 0x23, 0x21, 0x28, 0x23, 0x24, 0x25, 0x26, 0x5E, 0x61, 0x31, 0x63, 0x5A, 0x2C,
    0x54,
];

fn derive_key_v2(raw: &[u8]) -> Result<Vec<u8>> {
    let buf = decrypt_tencent_tea(raw, &DERIVE_V2_KEY1)?;
    let buf = decrypt_tencent_tea(&buf, &DERIVE_V2_KEY2)?;
    let decoded = B64
        .decode(&buf)
        .map_err(|e| anyhow!("deriveKeyV2 base64: {e}"))?;
    Ok(decoded)
}

fn derive_key_v1(raw: &[u8]) -> Result<Vec<u8>> {
    if raw.len() < 16 {
        bail!("key length is too short");
    }
    let simple_key = simple_make_key(106, 8);
    let mut tea_key = [0u8; 16];
    for i in 0..8 {
        tea_key[i << 1] = simple_key[i];
        tea_key[i << 1 | 1] = raw[i];
    }
    let rs = decrypt_tencent_tea(&raw[8..], &tea_key)?;
    let mut out = raw[..8].to_vec();
    out.extend_from_slice(&rs);
    Ok(out)
}

pub fn derive_key(raw_key: &[u8]) -> Result<Vec<u8>> {
    let raw_key = trim_nuls(raw_key);
    let decoded = B64
        .decode(raw_key)
        .map_err(|e| anyhow!("derive_key base64: {e}"))?;
    if decoded.starts_with(RAW_KEY_PREFIX_V2) {
        return derive_key_v2(&decoded[RAW_KEY_PREFIX_V2.len()..]);
    }
    derive_key_v1(&decoded)
}

fn trim_nuls(data: &[u8]) -> &[u8] {
    let end = data.iter().rposition(|&b| b != 0).map_or(0, |i| i + 1);
    &data[..end]
}


const STATIC_CIPHER_BOX: [u8; 256] = [
    0x77, 0x48, 0x32, 0x73, 0xDE, 0xF2, 0xC0, 0xC8, 0x95, 0xEC, 0x30, 0xB2, 0x51, 0xC3, 0xE1,
    0xA0, 0x9E, 0xE6, 0x9D, 0xCF, 0xFA, 0x7F, 0x14, 0xD1, 0xCE, 0xB8, 0xDC, 0xC3, 0x4A, 0x67,
    0x93, 0xD6, 0x28, 0xC2, 0x91, 0x70, 0xCA, 0x8D, 0xA2, 0xA4, 0xF0, 0x08, 0x61, 0x90, 0x7E,
    0x6F, 0xA2, 0xE0, 0xEB, 0xAE, 0x3E, 0xB6, 0x67, 0xC7, 0x92, 0xF4, 0x91, 0xB5, 0xF6, 0x6C,
    0x5E, 0x84, 0x40, 0xF7, 0xF3, 0x1B, 0x02, 0x7F, 0xD5, 0xAB, 0x41, 0x89, 0x28, 0xF4, 0x25,
    0xCC, 0x52, 0x11, 0xAD, 0x43, 0x68, 0xA6, 0x41, 0x8B, 0x84, 0xB5, 0xFF, 0x2C, 0x92, 0x4A,
    0x26, 0xD8, 0x47, 0x6A, 0x7C, 0x95, 0x61, 0xCC, 0xE6, 0xCB, 0xBB, 0x3F, 0x47, 0x58, 0x89,
    0x75, 0xC3, 0x75, 0xA1, 0xD9, 0xAF, 0xCC, 0x08, 0x73, 0x17, 0xDC, 0xAA, 0x9A, 0xA2, 0x16,
    0x41, 0xD8, 0xA2, 0x06, 0xC6, 0x8B, 0xFC, 0x66, 0x34, 0x9F, 0xCF, 0x18, 0x23, 0xA0, 0x0A,
    0x74, 0xE7, 0x2B, 0x27, 0x70, 0x92, 0xE9, 0xAF, 0x37, 0xE6, 0x8C, 0xA7, 0xBC, 0x62, 0x65,
    0x9C, 0xC2, 0x08, 0xC9, 0x88, 0xB3, 0xF3, 0x43, 0xAC, 0x74, 0x2C, 0x0F, 0xD4, 0xAF, 0xA1,
    0xC3, 0x01, 0x64, 0x95, 0x4E, 0x48, 0x9F, 0xF4, 0x35, 0x78, 0x95, 0x7A, 0x39, 0xD6, 0x6A,
    0xA0, 0x6D, 0x40, 0xE8, 0x4F, 0xA8, 0xEF, 0x11, 0x1D, 0xF3, 0x1B, 0x3F, 0x3F, 0x07, 0xDD,
    0x6F, 0x5B, 0x19, 0x30, 0x19, 0xFB, 0xEF, 0x0E, 0x37, 0xF0, 0x0E, 0xCD, 0x16, 0x49, 0xFE,
    0x53, 0x47, 0x13, 0x1A, 0xBD, 0xA4, 0xF1, 0x40, 0x19, 0x60, 0x0E, 0xED, 0x68, 0x09, 0x06,
    0x5F, 0x4D, 0xCF, 0x3D, 0x1A, 0xFE, 0x20, 0x77, 0xE4, 0xD9, 0xDA, 0xF9, 0xA4, 0x2B, 0x76,
    0x1C, 0x71, 0xDB, 0x00, 0xBC, 0xFD, 0x0C, 0x6C, 0xA5, 0x47, 0xF7, 0xF6, 0x00, 0x79, 0x4A,
    0x11,
];

trait StreamCipher {
    fn decrypt(&self, buf: &mut [u8], offset: usize);
}

struct StaticCipher;
impl StreamCipher for StaticCipher {
    fn decrypt(&self, buf: &mut [u8], offset: usize) {
        for (i, b) in buf.iter_mut().enumerate() {
            let mut o = offset + i;
            if o > 0x7FFF {
                o %= 0x7FFF;
            }
            *b ^= STATIC_CIPHER_BOX[(o * o + 27) & 0xff];
        }
    }
}

struct MapCipher {
    key: Vec<u8>,
}
impl StreamCipher for MapCipher {
    fn decrypt(&self, buf: &mut [u8], offset: usize) {
        let size = self.key.len();
        for (i, b) in buf.iter_mut().enumerate() {
            let mut o = offset + i;
            if o > 0x7FFF {
                o %= 0x7FFF;
            }
            let idx = (o * o + 71214) % size;
            let value = self.key[idx];
            let bits = (idx & 0x7) as u32;
            let rotate = (bits + 4) % 8;
            *b ^= (value << rotate) | (value >> rotate);
        }
    }
}

struct Rc4Cipher {
    box_: Vec<u8>,
    key: Vec<u8>,
    hash: u32,
    n: usize,
}

impl Rc4Cipher {
    fn new(key: &[u8]) -> Self {
        let n = key.len();
        let mut box_ = vec![0u8; n];
        for (i, b) in box_.iter_mut().enumerate() {
            *b = i as u8;
        }
        let mut j = 0usize;
        for i in 0..n {
            j = (j + box_[i] as usize + key[i % n] as usize) % n;
            box_.swap(i, j);
        }
        let mut hash: u32 = 1;
        for i in 0..n {
            let v = key[i] as u32;
            if v == 0 {
                continue;
            }
            let next = hash.wrapping_mul(v);
            if next == 0 || next <= hash {
                break;
            }
            hash = next;
        }
        Self {
            box_,
            key: key.to_vec(),
            hash,
            n,
        }
    }

    fn segment_skip(&self, id: usize) -> usize {
        let seed = self.key[id % self.n] as f64;
        if seed == 0.0 {
            return 0;
        }
        let idx = (self.hash as f64 / ((id + 1) as f64 * seed) * 100.0) as i64;
        (idx.rem_euclid(self.n as i64)) as usize
    }

    fn enc_first_segment(&self, buf: &mut [u8], offset: usize) {
        for (i, b) in buf.iter_mut().enumerate() {
            *b ^= self.key[self.segment_skip(offset + i)];
        }
    }

    fn enc_a_segment(&self, buf: &mut [u8], offset: usize) {
        let mut box_ = self.box_.clone();
        let (mut j, mut k) = (0usize, 0usize);
        let skip_len = (offset % SEGMENT_SIZE) + self.segment_skip(offset / SEGMENT_SIZE);
        let mut i: isize = -(skip_len as isize);
        let mut buf_idx = 0usize;
        while i < buf.len() as isize {
            j = (j + 1) % self.n;
            k = (box_[j] as usize + k) % self.n;
            box_.swap(j, k);
            if i >= 0 {
                buf[buf_idx] ^= box_[(box_[j] as usize + box_[k] as usize) % self.n];
                buf_idx += 1;
            }
            i += 1;
        }
    }
}

const SEGMENT_SIZE: usize = 5120;
const FIRST_SEGMENT_SIZE: usize = 128;

impl StreamCipher for Rc4Cipher {
    fn decrypt(&self, buf: &mut [u8], offset: usize) {
        let total = buf.len();
        let mut processed = 0usize;
        let mut off = offset;

        if off < FIRST_SEGMENT_SIZE {
            let block = total.min(FIRST_SEGMENT_SIZE - off);
            self.enc_first_segment(&mut buf[..block], off);
            off += block;
            processed += block;
            if processed == total {
                return;
            }
        }
        if off % SEGMENT_SIZE != 0 {
            let block = (total - processed).min(SEGMENT_SIZE - off % SEGMENT_SIZE);
            self.enc_a_segment(&mut buf[processed..processed + block], off);
            off += block;
            processed += block;
            if processed == total {
                return;
            }
        }
        while total - processed > SEGMENT_SIZE {
            self.enc_a_segment(&mut buf[processed..processed + SEGMENT_SIZE], off);
            off += SEGMENT_SIZE;
            processed += SEGMENT_SIZE;
        }
        if total - processed > 0 {
            self.enc_a_segment(&mut buf[processed..], off);
        }
    }
}

enum Cipher {
    Static(StaticCipher),
    Map(MapCipher),
    Rc4(Rc4Cipher),
}

impl Cipher {
    fn from_key(key: &[u8]) -> Cipher {
        if key.len() > 300 {
            Cipher::Rc4(Rc4Cipher::new(key))
        } else if !key.is_empty() {
            Cipher::Map(MapCipher {
                key: key.to_vec(),
            })
        } else {
            Cipher::Static(StaticCipher)
        }
    }

    fn decrypt(&self, buf: &mut [u8], offset: usize) {
        match self {
            Cipher::Static(c) => c.decrypt(buf, offset),
            Cipher::Map(c) => c.decrypt(buf, offset),
            Cipher::Rc4(c) => c.decrypt(buf, offset),
        }
    }
}


pub struct MusicExTag {
    pub song_id: u32,
    pub media_id: String,
    pub media_file_name: String,
    pub tag_size: u32,
}

fn read_unicode_tag_name(buf: &[u8], max_len: usize) -> String {
    let mut out = Vec::new();
    let mut i = 0;
    while i < max_len && i < buf.len() {
        let chr = buf[i];
        if chr == 0 {
            break;
        }
        out.push(chr);
        i += 2;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn parse_musicex_tag(data: &[u8]) -> Result<MusicExTag> {
    if data.len() < 16 {
        bail!("无法解析的头文件或行为");
    }
    let tail = &data[data.len() - 16..];
    let tag_size = u32::from_le_bytes(tail[0..4].try_into().unwrap());
    let tag_version = u32::from_le_bytes(tail[4..8].try_into().unwrap());
    if &tail[8..] != b"musicex\0" {
        bail!("无法解析的头文件或行为");
    }
    if tag_version != 1 {
        bail!("无法解析的头文件或行为");
    }
    if tag_size < 0xC0 || tag_size as usize > data.len() {
        bail!("无法解析的头文件或行为");
    }
    let tag = &data[data.len() - tag_size as usize..];
    Ok(MusicExTag {
        song_id: u32::from_le_bytes(tag[0x00..0x04].try_into().unwrap()),
        media_id: read_unicode_tag_name(&tag[0x0C..], 30 * 2),
        media_file_name: read_unicode_tag_name(&tag[0x48..], 50 * 2),
        tag_size,
    })
}

pub fn is_musicex(data: &[u8]) -> bool {
    data.len() >= 16 && &data[data.len() - 8..] == b"musicex\0"
}


pub fn qmc_decrypt(data: &[u8], keys: &HashMap<String, String>) -> Result<(Vec<u8>, String)> {
    if data.len() < 8 {
        bail!("qmc: file too small");
    }
    let suffix = &data[data.len() - 4..];
    let mut key: Option<Vec<u8>> = None;
    let audio_len: usize;

    match suffix {
        b"QTag" => {
            let meta_len =
                u32::from_be_bytes(data[data.len() - 8..data.len() - 4].try_into().unwrap())
                    as usize;
            audio_len = data.len() - 8 - meta_len;
            let meta = &data[audio_len..data.len() - 8];
            let text = String::from_utf8_lossy(meta);
            let items: Vec<&str> = text.split(',').collect();
            if items.len() != 3 {
                bail!("无法解析的头文件或行为");
            }
            key = Some(derive_key(items[0].as_bytes())?);
        }
        b"STag" => {
            bail!("执行部分操作时发生错误");
        }
        b"cex\0" => {
            let tag = parse_musicex_tag(data)?;
            audio_len = data.len() - tag.tag_size as usize;
            if let Some(ekey) = keys.get(&tag.media_file_name) {
                key = Some(derive_key(ekey.as_bytes())?);
            } else {
                bail!("执行部分操作时发生错误");
            }
        }
        _ => {
            let size = u32::from_le_bytes(suffix.try_into().unwrap()) as usize;
            if size > 0 && size <= 0xFFFF {
                audio_len = data.len() - 4 - size;
                let raw = trim_nuls(&data[audio_len..data.len() - 4]);
                key = Some(derive_key(raw)?);
            } else {
                audio_len = data.len();
            }
        }
    }

    if audio_len > data.len() {
        bail!("无法解析的头文件或行为");
    }
    let cipher = Cipher::from_key(key.as_deref().unwrap_or(&[]));
    let mut out = data[..audio_len].to_vec();
    cipher.decrypt(&mut out, 0);
    let ext = crate::decrypt::detect_audio_ext(&out).to_string();
    Ok((out, ext))
}
