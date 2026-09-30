// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// Archoera Subsonic 转码器（cdylib）
// C ABI：archoera_transcode_mp3 —— symphonia 解码 + mp3lame 编码，输出 MP3 到文件
//
// 原本为 CLI（stdout 输出 MP3 流），按用户决策改为动态库 + FFI：
// Go 侧经 dlopen 调用本符号，规避子进程与 stdin/stdout。
use anyhow::{anyhow, Context, Result};
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use symphonia::core::audio::GenericAudioBufferRef;
use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, TrackType};
use symphonia::core::io::{MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;

// ============================================================
// 统一日志 sink（对齐 downloader）：宿主经
// archoera_transcoder_set_log_sink 注入 libarchoera_log 的
// archoera_log_write 指针；未注入时回退 eprintln!。
// 级别数值对齐 archoera_log.h：0=DEBUG 1=INFO 2=WARN 3=ERROR 4=FATAL。
// ============================================================

/// 注入的日志 sink 函数指针（0 = 未注入）。参数：level, tag, message。
type LogSink = unsafe extern "C" fn(c_int, *const c_char, *const c_char);
static LOG_SINK: AtomicUsize = AtomicUsize::new(0);
/// 最小级别（低于此级别直接丢弃，避免无谓格式化）。
static LOG_MIN_LEVEL: AtomicUsize = AtomicUsize::new(1); // INFO

/// 注入统一日志 sink（宿主 Dart→Go 经 dlopen 转发）。fn_ptr=NULL 注销并回退
/// eprintln!。幂等；可在转码前后调用。
#[no_mangle]
pub extern "C" fn archoera_transcoder_set_log_sink(fn_ptr: *const c_void, min_level: c_int) {
    let lvl = if min_level < 0 { 0usize } else { min_level as usize };
    LOG_MIN_LEVEL.store(lvl.min(4), Ordering::Release);
    LOG_SINK.store(fn_ptr as usize, Ordering::Release);
}

fn level_name(level: i32) -> &'static str {
    match level {
        0 => "DEBUG",
        2 => "WARN",
        3 => "ERROR",
        4 => "FATAL",
        _ => "INFO",
    }
}

/// 统一输出：已注入 sink 时经其回调（tag=transcoder），否则 eprintln 回退。
fn log_emit(level: i32, args: std::fmt::Arguments<'_>) {
    if (level as usize) < LOG_MIN_LEVEL.load(Ordering::Acquire) {
        return;
    }
    let raw = LOG_SINK.load(Ordering::Acquire);
    if raw != 0 {
        let sink: LogSink = unsafe { std::mem::transmute(raw) };
        if let (Ok(tag), Ok(msg)) = (CString::new("transcoder"), CString::new(format!("{}", args))) {
            unsafe { sink(level, tag.as_ptr(), msg.as_ptr()) };
            return;
        }
    }
    eprintln!("[transcoder] {}: {}", level_name(level), args);
}

macro_rules! tlog_warn {
    ($($arg:tt)*) => { log_emit(2, format_args!($($arg)*)) };
}
macro_rules! tlog_error {
    ($($arg:tt)*) => { log_emit(3, format_args!($($arg)*)) };
}

/// C 入口：把 input 转码为 MP3 写入 output。
/// bitrate: kbps（0 表示默认 192）；max_sample_rate: Hz（0 默认 48000）；
/// channels: 1/2（0 表示保持原样）；skip_seconds: 跳过前 N 秒（timeOffset 续播）。
/// 返回 0 成功；1 参数错误；2 转码失败。
#[no_mangle]
pub extern "C" fn archoera_transcode_mp3(
    input_path: *const c_char,
    output_path: *const c_char,
    bitrate: c_int,
    max_sample_rate: c_int,
    channels: c_int,
    skip_seconds: c_int,
) -> c_int {
    if input_path.is_null() || output_path.is_null() {
        tlog_error!("null 参数");
        return 1;
    }
    let input = match unsafe { CStr::from_ptr(input_path) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => {
            tlog_error!("非法输入路径");
            return 1;
        }
    };
    let output = match unsafe { CStr::from_ptr(output_path) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => {
            tlog_error!("非法输出路径");
            return 1;
        }
    };

    match transcode_to_file(&input, &output, bitrate, max_sample_rate, channels, skip_seconds) {
        Ok(()) => 0,
        Err(e) => {
            tlog_error!("转码失败: {:#}", e);
            2
        }
    }
}

struct Params {
    input: PathBuf,
    output: PathBuf,
    bitrate: u32,
    max_sample_rate: u32,
    channels: Option<u16>,
    skip_seconds: u32,
}

fn transcode_to_file(
    input: &str,
    output: &str,
    bitrate: c_int,
    max_sample_rate: c_int,
    channels: c_int,
    skip_seconds: c_int,
) -> Result<()> {
    let params = Params {
        input: PathBuf::from(input),
        output: PathBuf::from(output),
        bitrate: if bitrate > 0 { bitrate as u32 } else { 192 },
        max_sample_rate: if max_sample_rate > 0 {
            max_sample_rate as u32
        } else {
            48000
        },
        channels: match channels {
            1 | 2 => Some(channels as u16),
            _ => None,
        },
        skip_seconds: if skip_seconds > 0 { skip_seconds as u32 } else { 0 },
    };

    let file = File::create(&params.output)
        .with_context(|| format!("无法创建输出文件: {:?}", params.output))?;
    let mut out = BufWriter::new(file);
    transcode(&params, &mut out)?;
    out.flush().ok();
    Ok(())
}

fn transcode(args: &Params, out: &mut impl Write) -> Result<()> {
    let file = std::fs::File::open(&args.input)
        .with_context(|| format!("无法打开输入文件: {:?}", args.input))?;
    let mss = MediaSourceStream::new(Box::new(file), MediaSourceStreamOptions::default());

    let mut hint = Hint::new();
    if let Some(ext) = args.input.extension().and_then(|s| s.to_str()) {
        hint.with_extension(ext);
    }

    let mut format = symphonia::default::get_probe()
        .probe(&hint, mss, FormatOptions::default(), MetadataOptions::default())
        .map_err(|e| anyhow!("探测容器失败: {}", e))?;

    let track = format
        .default_track(TrackType::Audio)
        .ok_or_else(|| anyhow!("未找到可用音轨"))?;
    let track_id = track.id;
    let audio_params = track
        .codec_params
        .as_ref()
        .and_then(|p| p.audio())
        .ok_or_else(|| anyhow!("音轨缺少音频参数"))?;

    let mut decoder = symphonia::default::get_codecs()
        .make_audio_decoder(audio_params, &AudioDecoderOptions::default())
        .map_err(|e| anyhow!("创建解码器失败: {}", e))?;

    let in_sample_rate = audio_params
        .sample_rate
        .ok_or_else(|| anyhow!("无法获取采样率"))?;
    let in_channels = audio_params
        .channels
        .as_ref()
        .map(|c| c.count())
        .ok_or_else(|| anyhow!("无法获取声道数"))? as u16;

    // 输出参数：必要时降采样
    let out_sample_rate = in_sample_rate.min(args.max_sample_rate);
    let out_channels = args.channels.unwrap_or(in_channels.min(2));

    let mut builder = mp3lame_encoder::Builder::new()
        .ok_or_else(|| anyhow!("无法分配 LAME 编码器"))?;
    builder.set_sample_rate(out_sample_rate).map_err(|e| anyhow!("设置采样率失败: {:?}", e))?;
    builder.set_num_channels(out_channels as u8).map_err(|e| anyhow!("设置声道数失败: {:?}", e))?;
    let bitrate = match args.bitrate {
        8 => mp3lame_encoder::Bitrate::Kbps8,
        16 => mp3lame_encoder::Bitrate::Kbps16,
        24 => mp3lame_encoder::Bitrate::Kbps24,
        32 => mp3lame_encoder::Bitrate::Kbps32,
        40 => mp3lame_encoder::Bitrate::Kbps40,
        48 => mp3lame_encoder::Bitrate::Kbps48,
        64 => mp3lame_encoder::Bitrate::Kbps64,
        80 => mp3lame_encoder::Bitrate::Kbps80,
        96 => mp3lame_encoder::Bitrate::Kbps96,
        112 => mp3lame_encoder::Bitrate::Kbps112,
        128 => mp3lame_encoder::Bitrate::Kbps128,
        160 => mp3lame_encoder::Bitrate::Kbps160,
        192 => mp3lame_encoder::Bitrate::Kbps192,
        224 => mp3lame_encoder::Bitrate::Kbps224,
        256 => mp3lame_encoder::Bitrate::Kbps256,
        320 => mp3lame_encoder::Bitrate::Kbps320,
        _ => return Err(anyhow!("不支持的比特率: {}", args.bitrate)),
    };
    builder.set_brate(bitrate).map_err(|e| anyhow!("设置比特率失败: {:?}", e))?;
    builder.set_quality(mp3lame_encoder::Quality::NearBest)
        .map_err(|e| anyhow!("设置质量失败: {:?}", e))?;
    let mut lame = builder.build().map_err(|e| anyhow!("构建 LAME 编码器失败: {:?}", e))?;

    // 处理降采样：简单线性抽取（仅当输入 > 目标）
    let resample_ratio = if out_sample_rate < in_sample_rate {
        Some((in_sample_rate, out_sample_rate))
    } else {
        None
    };

    let mut buf_interleaved: Vec<i16> = Vec::with_capacity(out_channels as usize * 1152 * 2);

    // timeOffset 跳过逻辑：累计跳过的样本数
    let skip_target = args.skip_seconds as u64 * out_sample_rate as u64;
    let mut skipped_samples: u64 = 0;

    loop {
        let packet = match format.next_packet() {
            Ok(Some(p)) => p,
            Ok(None) => break,
            Err(SymphoniaError::ResetRequired) => {
                tlog_warn!("解码器需要重置，跳过");
                continue;
            }
            Err(e) => {
                return Err(anyhow!("解码读取失败: {}", e));
            }
        };

        // 只解码选中的音轨（容器可能含视频/字幕等其它轨）
        if packet.track_id != track_id {
            continue;
        }

        let decoded = match decoder.decode(&packet) {
            Ok(buf) => buf,
            Err(e) => {
                tlog_warn!("跳过坏包: {}", e);
                continue;
            }
        };

        // 取出交错的 i16 PCM
        let frames = decoded.frames();
        if frames == 0 {
            continue;
        }

        // symphonia 输出可能是 i16/i32/f32/u8，统一转 i16
        let pcm = collect_pcm_i16(decoded, out_channels as usize);

        // 降采样
        let pcm = if let Some((in_rate, out_rate)) = resample_ratio {
            downsample(&pcm, in_rate as usize, out_rate as usize)
        } else {
            pcm
        };

        // timeOffset：跳过前 N 秒的 PCM 数据
        if skipped_samples < skip_target {
            let frame_samples = (pcm.len() / out_channels as usize) as u64;
            let remaining = skip_target - skipped_samples;
            if frame_samples <= remaining {
                skipped_samples += frame_samples;
                continue; // 整帧跳过
            }
            // 部分跳过：只保留尾部未跳过的部分
            let keep = (frame_samples - remaining) as usize * out_channels as usize;
            let partial = &pcm[pcm.len() - keep..];
            buf_interleaved.extend_from_slice(partial);
            skipped_samples = skip_target;
            flush_lame(&mut lame, &mut buf_interleaved, out_channels as usize, out)?;
            continue;
        }

        buf_interleaved.extend_from_slice(&pcm);

        // LAME 每次至少需要 1152 帧（单声道）或 1152*channels 个样本
        // 这里按块喂入
        flush_lame(&mut lame, &mut buf_interleaved, out_channels as usize, out)?;
    }

    // flush 剩余
    if !buf_interleaved.is_empty() {
        flush_lame(&mut lame, &mut buf_interleaved, out_channels as usize, out)?;
    }

    // flush encoder 内部缓冲（同样需要预分配：flush 至少需 7200 字节）
    let mut final_buf = Vec::with_capacity(7200);
    lame.flush_to_vec::<mp3lame_encoder::FlushNoGap>(&mut final_buf)
        .map_err(|e| anyhow!("LAME 编码器刷出失败: {:?}", e))?;
    if !final_buf.is_empty() {
        out.write_all(&final_buf)?;
    }

    Ok(())
}

/// 将 symphonia 的通用音频缓冲转换为交错 i16 PCM。
///
/// symphonia 负责把 u8/s16/s24/s32/f32/f64 统一转换到目标 i16；这里只需按其
/// 规范复制交错样本，并在必要时仅保留每帧前 [target_channels] 个声道。
fn collect_pcm_i16(buf: GenericAudioBufferRef<'_>, target_channels: usize) -> Vec<i16> {
    let frames = buf.frames();
    if frames == 0 {
        return Vec::new();
    }
    let channels = buf.spec().channels().count();
    if channels == 0 {
        return Vec::new();
    }
    let out_channels = target_channels.min(channels);

    let mut interleaved = vec![0i16; frames * channels];
    buf.copy_to_slice_interleaved(&mut interleaved);

    if out_channels == channels {
        return interleaved;
    }

    // 丢弃多余声道：每帧仅保留前 out_channels 个样本
    let mut out = Vec::with_capacity(frames * out_channels);
    for frame in interleaved.chunks_exact(channels) {
        out.extend_from_slice(&frame[..out_channels]);
    }
    out
}

/// 简单线性抽取降采样：每 step 个样本取一个
fn downsample(pcm: &[i16], in_rate: usize, out_rate: usize) -> Vec<i16> {
    if in_rate == out_rate {
        return pcm.to_vec();
    }
    let ratio_num = in_rate / out_rate;
    if ratio_num == 0 || in_rate % out_rate != 0 {
        // 非整数比——退回原值（保持正确性）
        return pcm.to_vec();
    }
    let mut out = Vec::with_capacity(pcm.len() / ratio_num + 1);
    let mut i = 0;
    while i < pcm.len() {
        out.push(pcm[i]);
        i += ratio_num;
    }
    out
}

/// 喂入 PCM 数据给 LAME 编码器，并写出已编码的 MP3
fn flush_lame(
    lame: &mut mp3lame_encoder::Encoder,
    buf: &mut Vec<i16>,
    channels: usize,
    out: &mut impl Write,
) -> Result<()> {
    let frame_size = 1152 * channels;
    // mp3lame-encoder 的 encode_to_vec 依赖 Vec 预分配 capacity
    // （spare_capacity_mut 为空时 LAME 写空指针 → 段错误），必须先 reserve
    let mut mp3_buf = Vec::with_capacity(mp3lame_encoder::max_required_buffer_size(frame_size));
    while buf.len() >= frame_size {
        let chunk: Vec<i16> = buf.drain(..frame_size).collect();
        let old_len = mp3_buf.len();
        if channels == 1 {
            lame.encode_to_vec(mp3lame_encoder::MonoPcm(&chunk), &mut mp3_buf)
                .map_err(|e| anyhow!("LAME 单声道编码失败: {:?}", e))?;
        } else {
            // 立体声：交错数据直接用 InterleavedPcm
            lame.encode_to_vec(mp3lame_encoder::InterleavedPcm(&chunk), &mut mp3_buf)
                .map_err(|e| anyhow!("LAME 立体声编码失败: {:?}", e))?;
        }
        if mp3_buf.len() > old_len {
            out.write_all(&mp3_buf[old_len..])?;
            mp3_buf.truncate(old_len);
        }
    }
    Ok(())
}
