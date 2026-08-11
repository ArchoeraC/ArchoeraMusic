// Archoera Subsonic 转码器（cdylib）
// C ABI：archoera_transcode_mp3 —— symphonia 解码 + mp3lame 编码，输出 MP3 到文件
//
// 原本为 CLI（stdout 输出 MP3 流），按用户决策改为动态库 + FFI：
// Go 侧经 dlopen 调用本符号，规避子进程与 stdin/stdout。
use anyhow::{anyhow, Context, Result};
use std::ffi::{c_char, c_int, CStr};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use symphonia::core::audio::{AudioBufferRef, Signal};
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::{MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

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
        eprintln!("[archoera-transcoder] null 参数");
        return 1;
    }
    let input = match unsafe { CStr::from_ptr(input_path) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => {
            eprintln!("[archoera-transcoder] 非法输入路径");
            return 1;
        }
    };
    let output = match unsafe { CStr::from_ptr(output_path) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => {
            eprintln!("[archoera-transcoder] 非法输出路径");
            return 1;
        }
    };

    match transcode_to_file(&input, &output, bitrate, max_sample_rate, channels, skip_seconds) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("[archoera-transcoder] 转码失败: {:#}", e);
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

    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| anyhow!("探测容器失败: {}", e))?;

    let mut format = probed.format;

    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .cloned()
        .ok_or_else(|| anyhow!("未找到可用音轨"))?;

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| anyhow!("创建解码器失败: {}", e))?;

    let in_sample_rate = track
        .codec_params
        .sample_rate
        .ok_or_else(|| anyhow!("无法获取采样率"))?;
    let in_channels = track
        .codec_params
        .channels
        .ok_or_else(|| anyhow!("无法获取声道数"))?
        .count() as u16;

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
            Ok(p) => p,
            Err(SymphoniaError::IoError(ref e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(SymphoniaError::ResetRequired) => {
                eprintln!("[archoera-transcoder] 解码器需要重置，跳过");
                continue;
            }
            Err(e) => {
                return Err(anyhow!("解码读取失败: {}", e));
            }
        };

        let decoded = match decoder.decode(&packet) {
            Ok(buf) => buf,
            Err(e) => {
                eprintln!("[archoera-transcoder] 跳过坏包: {}", e);
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

/// 将 symphonia 的 AudioBufferRef 转换为交错 i16 PCM
fn collect_pcm_i16(buf: AudioBufferRef, target_channels: usize) -> Vec<i16> {
    use symphonia::core::audio::AudioBufferRef::*;
    let frames = buf.frames();
    let channels = buf.spec().channels.count();
    let out_channels = target_channels.min(channels);

    let mut out = Vec::with_capacity(frames * out_channels);

    match buf {
        U8(b) => {
            for i in 0..frames {
                for ch in 0..out_channels {
                    let s = *b.chan(ch).get(i).unwrap_or(&0) as i32 - 128;
                    let v = (s * 256).clamp(i32::MIN, i32::MAX) as i16;
                    out.push(v);
                }
            }
        }
        S16(b) => {
            for i in 0..frames {
                for ch in 0..out_channels {
                    out.push(*b.chan(ch).get(i).unwrap_or(&0));
                }
            }
        }
        S32(b) => {
            for i in 0..frames {
                for ch in 0..out_channels {
                    let s = b.chan(ch).get(i).copied().unwrap_or(0);
                    out.push((s >> 16).clamp(i16::MIN as i32, i16::MAX as i32) as i16);
                }
            }
        }
        F32(b) => {
            for i in 0..frames {
                for ch in 0..out_channels {
                    let s = b.chan(ch).get(i).copied().unwrap_or(0.0);
                    out.push(float_to_i16(s as f64));
                }
            }
        }
        F64(b) => {
            for i in 0..frames {
                for ch in 0..out_channels {
                    let s = b.chan(ch).get(i).copied().unwrap_or(0.0);
                    out.push(float_to_i16(s));
                }
            }
        }
        _ => {
            // S24（打包 24-bit/i24 类型）极少见，跳过
            let _ = frames;
        }
    }
    out
}

fn float_to_i16(s: f64) -> i16 {
    let v = (s * 32767.0).clamp(-32768.0, 32767.0);
    v as i16
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
