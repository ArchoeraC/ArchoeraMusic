//! 变速 / 变调 — signalsmith-stretch C FFI 封装
//!
//! 为 archoera-audio-engine C 管线提供 tempo 处理能力。

use signalsmith_stretch::Stretch;
use std::os::raw::c_void;

const FLOAT_EQ_EPS: f32 = 1e-4;

struct TempoProcessor {
    stretch: Stretch,
    channels: u32,
    #[allow(dead_code)]
    sample_rate: u32,
    speed: f32,
    pitch_semitones: f32,
    pitch_sync: bool,
    applied_transpose: f32,
    enabled: bool,
}

impl TempoProcessor {
    fn new(channels: u32, sample_rate: u32) -> Self {
        Self {
            stretch: Stretch::preset_default(channels, sample_rate),
            channels,
            sample_rate,
            speed: 1.0,
            pitch_semitones: 0.0,
            pitch_sync: true,
            applied_transpose: 0.0,
            enabled: true,
        }
    }

    fn effective_transpose(&self) -> f32 {
        if self.pitch_sync {
            self.pitch_semitones
        } else {
            12.0 * self.speed.log2()
        }
    }

    fn sync_transpose(&mut self) {
        let target = self.effective_transpose();
        if (target - self.applied_transpose).abs() > FLOAT_EQ_EPS {
            self.stretch.set_transpose_factor_semitones(target, None);
            self.applied_transpose = target;
        }
    }

    fn is_bypass(&self) -> bool {
        !self.enabled
            || ((self.speed - 1.0).abs() < FLOAT_EQ_EPS
                && self.effective_transpose().abs() < FLOAT_EQ_EPS)
    }

    fn process(&mut self, input: &[f32], output: &mut Vec<f32>) -> i32 {
        if input.is_empty() {
            return 0;
        }

        if self.is_bypass() {
            output.extend_from_slice(input);
            return (input.len() / self.channels as usize) as i32;
        }

        let ch = self.channels as usize;
        let input_frames = input.len() / ch;
        if input_frames == 0 {
            return 0;
        }

        let output_frames = ((input_frames as f32) / self.speed).round() as usize;
        if output_frames == 0 {
            return 0;
        }

        let start = output.len();
        output.resize(start + output_frames * ch, 0.0);
        self.stretch.process(input, &mut output[start..]);
        output_frames as i32
    }
}

// ── C FFI (导出符号以 rs_tempo_ 为前缀，避免与 C wrapper 冲突) ──

#[no_mangle]
pub extern "C" fn rs_tempo_create(sample_rate: i32, channels: i32) -> *mut c_void {
    let p = Box::new(TempoProcessor::new(channels as u32, sample_rate as u32));
    Box::into_raw(p) as *mut c_void
}

#[no_mangle]
pub extern "C" fn rs_tempo_destroy(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(handle as *mut TempoProcessor));
    }
}

#[no_mangle]
pub extern "C" fn rs_tempo_reset(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let p = unsafe { &mut *(handle as *mut TempoProcessor) };
    p.stretch.reset();
}

#[no_mangle]
pub extern "C" fn rs_tempo_set_enabled(handle: *mut c_void, enabled: bool) {
    if handle.is_null() {
        return;
    }
    let p = unsafe { &mut *(handle as *mut TempoProcessor) };
    p.enabled = enabled;
}

#[no_mangle]
pub extern "C" fn rs_tempo_set_speed(handle: *mut c_void, speed: f32) {
    if handle.is_null() {
        return;
    }
    let p = unsafe { &mut *(handle as *mut TempoProcessor) };
    p.speed = speed.clamp(0.5, 2.0);
    if !p.pitch_sync {
        p.sync_transpose();
    }
}

#[no_mangle]
pub extern "C" fn rs_tempo_set_pitch(handle: *mut c_void, semitones: f32) {
    if handle.is_null() {
        return;
    }
    let p = unsafe { &mut *(handle as *mut TempoProcessor) };
    p.pitch_semitones = semitones.clamp(-12.0, 12.0);
    if p.pitch_sync {
        p.sync_transpose();
    }
}

#[no_mangle]
pub extern "C" fn rs_tempo_set_pitch_sync(handle: *mut c_void, sync: bool) {
    if handle.is_null() {
        return;
    }
    let p = unsafe { &mut *(handle as *mut TempoProcessor) };
    p.pitch_sync = sync;
    p.sync_transpose();
}

#[no_mangle]
pub extern "C" fn rs_tempo_process(
    handle: *mut c_void,
    input: *const f32,
    input_samples: i32,
    output: *mut f32,
    output_capacity: i32,
) -> i32 {
    if handle.is_null() || input.is_null() || output.is_null() {
        return -1;
    }
    let p = unsafe { &mut *(handle as *mut TempoProcessor) };
    let ch = p.channels as usize;
    let inp = unsafe { std::slice::from_raw_parts(input, input_samples as usize * ch) };

    let max_out = if p.is_bypass() {
        input_samples as usize * ch
    } else {
        (((input_samples as f32) / p.speed).ceil() as usize + 1) * ch
    };

    let cap = (output_capacity as usize * ch).min(max_out);
    let mut out_vec = Vec::with_capacity(cap);

    let result = p.process(inp, &mut out_vec);

    let copy_len = out_vec.len().min(output_capacity as usize * ch);
    unsafe {
        std::ptr::copy_nonoverlapping(out_vec.as_ptr(), output, copy_len);
    }

    result
}
