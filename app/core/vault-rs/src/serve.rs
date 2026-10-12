// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 按需会话（与 C# ServeSession.cs 协议一致）：血缘校验 → 握手 → 命令循环 → 自退。

use std::io::Write;

use crate::encoding::{b64_decode, b64_encode};
use crate::errors::{Result, VaultError};
use crate::format::SlotsMode;
use crate::guard;
use crate::service::{VaultService, AUTH_UID};
use crate::MARKER;

pub const HANDSHAKE_TIMEOUT_SECONDS: i32 = 10;
pub const IDLE_TIMEOUT_SECONDS: i32 = 30;

/// 单次读超时 / IO 错误。
pub enum ReadErr {
    Timeout,
    Io,
}

/// 行缓冲读取器（fd 上阻塞读 + 单次超时；无忙轮询）。
#[cfg(unix)]
pub struct LineReader {
    fd: i32,
    buf: Vec<u8>,
    start: usize,
}

#[cfg(unix)]
impl LineReader {
    pub fn new(fd: i32) -> Self {
        Self {
            fd,
            buf: Vec::new(),
            start: 0,
        }
    }

    /// 读取一行（剥离行尾 `\r\n`）；EOF 返回 Ok(None)；超时返回 Err(Timeout)。
    pub fn read_line(&mut self, timeout_ms: i32) -> std::result::Result<Option<String>, ReadErr> {
        loop {
            if let Some(idx) = self.buf[self.start..].iter().position(|&b| b == b'\n') {
                let end = self.start + idx;
                let line = self.buf[self.start..end].to_vec();
                self.start = end + 1;
                self.compact();
                return Ok(Some(decode_line(&line)));
            }
            let mut pfd = libc::pollfd {
                fd: self.fd,
                events: libc::POLLIN,
                revents: 0,
            };
            let ready = unsafe { libc::poll(&mut pfd, 1, timeout_ms) };
            if ready == 0 {
                return Err(ReadErr::Timeout);
            }
            if ready < 0 {
                return Err(ReadErr::Io);
            }
            let mut tmp = [0u8; 4096];
            let n = unsafe { libc::read(self.fd, tmp.as_mut_ptr() as *mut libc::c_void, tmp.len()) };
            if n < 0 {
                return Err(ReadErr::Io);
            }
            if n == 0 {
                if self.start < self.buf.len() {
                    let line = self.buf[self.start..].to_vec();
                    self.start = self.buf.len();
                    self.compact();
                    return Ok(Some(decode_line(&line)));
                }
                return Ok(None);
            }
            self.buf.extend_from_slice(&tmp[..n as usize]);
        }
    }

    fn compact(&mut self) {
        if self.start > 0 && self.start == self.buf.len() {
            self.buf.clear();
            self.start = 0;
        } else if self.start > 4096 {
            self.buf.drain(0..self.start);
            self.start = 0;
        }
    }
}

#[cfg(unix)]
fn decode_line(line: &[u8]) -> String {
    let mut l = line;
    if l.last() == Some(&b'\r') {
        l = &l[..l.len() - 1];
    }
    String::from_utf8_lossy(l).into_owned()
}

/// 非 unix（Windows）回退：标准输入阻塞读取（无超时；V1 最小路径，保证编译）。
#[cfg(not(unix))]
pub struct LineReader {
    inner: std::io::BufReader<std::io::Stdin>,
}

#[cfg(not(unix))]
impl LineReader {
    pub fn new(_fd: i32) -> Self {
        Self {
            inner: std::io::BufReader::new(std::io::stdin()),
        }
    }

    pub fn read_line(&mut self, _timeout_ms: i32) -> std::result::Result<Option<String>, ReadErr> {
        use std::io::BufRead;
        let mut s = String::new();
        match self.inner.read_line(&mut s) {
            Ok(0) => Ok(None),
            Ok(_) => {
                while s.ends_with('\n') || s.ends_with('\r') {
                    s.pop();
                }
                Ok(Some(s))
            }
            Err(_) => Err(ReadErr::Io),
        }
    }
}

/// 输出一行到 stdout 并 flush。
pub fn emit(s: &str) {
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    let _ = lock.write_all(s.as_bytes());
    let _ = lock.write_all(b"\n");
    let _ = lock.flush();
}

enum DispatchResult {
    Continue,
    Quit,
}

pub struct ServeSession {
    service: VaultService,
    parent_pid: i32,
}

impl ServeSession {
    pub fn new(data_dir: &str) -> Result<Self> {
        let service = VaultService::new(data_dir)?;
        let parent_pid = guard::verify_and_arm()?;
        Ok(Self {
            service,
            parent_pid,
        })
    }

    pub fn run(&self) -> i32 {
        if !self.service.initialized() {
            return fail("vault 未初始化，请先 init");
        }
        let mode = match self.service.mode() {
            Ok(m) => m,
            Err(e) => return fail(&e.message()),
        };
        let slot_mode = if mode == crate::format::VaultMode::Slots {
            self.service.slots_mode().unwrap_or(SlotsMode::None)
        } else {
            SlotsMode::None
        };
        let (min_fields, max_fields) = if mode == crate::format::VaultMode::Slots {
            match slot_mode {
                SlotsMode::M2b => (3, 3),
                SlotsMode::M2a => (4, 5),
                _ => (4, 4),
            }
        } else {
            (3, 3)
        };

        let mut reader = LineReader::new(0);

        // ── 握手 ──
        let line = match reader.read_line(HANDSHAKE_TIMEOUT_SECONDS * 1000) {
            Ok(Some(l)) => l,
            Ok(None) => String::new(),
            Err(ReadErr::Timeout) => return fail("握手超时"),
            Err(ReadErr::Io) => return fail("握手读取失败"),
        };
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < min_fields || parts.len() > max_fields || parts[0] != "handshake" {
            return fail(&handshake_usage(mode, slot_mode));
        }
        let h = match b64_decode(parts[1]) {
            Ok(v) => v,
            Err(_) => return fail("握手负载非 base64"),
        };
        let c = match b64_decode(parts[2]) {
            Ok(v) => v,
            Err(_) => return fail("握手负载非 base64"),
        };
        let secret = if parts.len() >= 4 {
            match b64_decode(parts[3]) {
                Ok(v) => Some(v),
                Err(_) => return fail("握手负载非 base64"),
            }
        } else {
            None
        };
        let label = if parts.len() >= 5 {
            match b64_decode(parts[4]) {
                Ok(v) => Some(String::from_utf8_lossy(&v).into_owned()),
                Err(_) => return fail("握手负载非 base64"),
            }
        } else {
            None
        };
        if h.len() != 32 || c.len() != 16 {
            return fail("握手负载长度错误");
        }
        if slot_mode == SlotsMode::M2a {
            if let Some(l) = &label {
                if l != "rec" {
                    return fail("握手标签未知：m2a 仅支持 \"rec\"（恢复码）");
                }
            }
        }

        // 解锁失败退避（§3.7）：锁定期间连尝试都不做。
        if let Some(secs) = self.service.lockout().locked_seconds(self.service.store()) {
            return fail(&VaultError::Lockout(secs).message());
        }

        let unlocked = (|| -> Result<(Vec<u8>, Vec<u8>)> {
            let master = self
                .service
                .load_master_key_into(secret.as_deref(), label.as_deref())?;
            let anchor = self.service.get_or_create_auth_anchor(&master)?;
            Ok((master, anchor))
        })();
        let (master, anchor) = match unlocked {
            Ok(v) => v,
            Err(VaultError::NeedRecovery(m)) => return fail(&format!("NEED_RECOVERY {m}")),
            Err(e @ VaultError::ShareBackendMismatch { .. }) => {
                return fail(&format!("SHARE_BACKEND_MISMATCH {}", e.message()))
            }
            Err(VaultError::ShareMissing(m)) => return fail(&format!("SHARE_MISSING {m}")),
            Err(VaultError::AuthTag(m)) => {
                self.service.lockout().record_failure(self.service.store());
                return fail(&format!("SHARE_MISMATCH {m}"));
            }
            Err(e) => {
                self.service.lockout().record_failure(self.service.store());
                return fail(&e.message());
            }
        };
        self.service.lockout().clear(self.service.store());

        let mac = crate::crypto::hmac_sha256(&h, &c);
        emit(&format!(
            "ok handshake {} {} {}",
            b64_encode(&anchor),
            b64_encode(&mac),
            MARKER
        ));

        // ── 命令循环 ──
        loop {
            let cmd = match reader.read_line(IDLE_TIMEOUT_SECONDS * 1000) {
                Ok(Some(l)) => l,
                Ok(None) => return 0,
                Err(ReadErr::Timeout) => return 0,
                Err(ReadErr::Io) => return 0,
            };
            match self.dispatch(&cmd, &master, &mut reader) {
                DispatchResult::Quit => return 0,
                DispatchResult::Continue => {}
            }
            if guard::parent_gone(self.parent_pid) {
                return 0;
            }
        }
    }

    fn dispatch(&self, line: &str, master: &[u8], reader: &mut LineReader) -> DispatchResult {
        let parts: Vec<&str> = line.split_whitespace().collect();
        match parts.first() {
            Some(&"quit") => {
                emit("ok");
                DispatchResult::Quit
            }
            Some(&"status") => {
                emit("ok {\"initialized\":true}");
                DispatchResult::Continue
            }
            Some(&"get") => {
                if parts.len() != 2 {
                    return err("get 需要 uid 参数");
                }
                self.handle_get(parts[1], master)
            }
            Some(&"set") => {
                if parts.len() != 2 {
                    return err("set 需要 uid 参数");
                }
                self.handle_set(parts[1], master, reader)
            }
            Some(&"delete") => {
                if parts.len() != 2 {
                    return err("delete 需要 uid 参数");
                }
                self.handle_delete(parts[1], master)
            }
            Some(&"destroy") => {
                match self.service.destroy() {
                    Ok(()) => emit("ok"),
                    Err(e) => return err(&e.message()),
                }
                DispatchResult::Continue
            }
            Some(other) => err(&format!("未知命令: {other}")),
            None => err("未知命令: "),
        }
    }

    fn handle_get(&self, uid: &str, master: &[u8]) -> DispatchResult {
        match self.service.get_with(uid, master) {
            Ok(None) => emit("ok null"),
            Ok(Some(got)) => emit(&format!("ok {}", b64_encode(&got))),
            Err(e) => return err(&e.message()),
        }
        DispatchResult::Continue
    }

    fn handle_set(&self, uid: &str, master: &[u8], reader: &mut LineReader) -> DispatchResult {
        if uid == AUTH_UID {
            return err("保留 uid，拒绝写入");
        }
        let payload = match reader.read_line(IDLE_TIMEOUT_SECONDS * 1000) {
            Ok(Some(p)) => p,
            Err(ReadErr::Timeout) => return err("set 负载读取超时"),
            _ => return err("set 缺少 stdin 负载行（base64）"),
        };
        if payload.is_empty() {
            return err("set 缺少 stdin 负载行（base64）");
        }
        let plain = match b64_decode(&payload) {
            Ok(p) => p,
            Err(_) => return err("set 负载非 base64"),
        };
        match self.service.set_with(uid, &plain, master) {
            Ok(()) => emit("ok"),
            Err(e) => return err(&e.message()),
        }
        DispatchResult::Continue
    }

    fn handle_delete(&self, uid: &str, master: &[u8]) -> DispatchResult {
        match self.service.delete_with(uid, master) {
            Ok(true) => emit("ok true"),
            Ok(false) => emit("ok false"),
            Err(e) => return err(&e.message()),
        }
        DispatchResult::Continue
    }
}

fn err(message: &str) -> DispatchResult {
    emit(&format!("err {message}"));
    DispatchResult::Continue
}

fn fail(message: &str) -> i32 {
    emit(&format!("err {message}"));
    1
}

fn handshake_usage(mode: crate::format::VaultMode, slot_mode: SlotsMode) -> String {
    if mode == crate::format::VaultMode::Slots {
        return match slot_mode {
            SlotsMode::M2b => {
                "握手格式错误：m2b 需要 `handshake <b64H> <b64C>`（device.key）".to_string()
            }
            SlotsMode::M2a => "握手格式错误：m2a 需要 `handshake <b64H> <b64C> <b64password>` 或 `… <b64恢复码> <b64\"rec\">`".to_string(),
            _ => "握手格式错误：m1 需要 `handshake <b64H> <b64C> <b64password>`".to_string(),
        };
    }
    "握手格式错误：需要 `handshake <b64H> <b64C>`".to_string()
}
