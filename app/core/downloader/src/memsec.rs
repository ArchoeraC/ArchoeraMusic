// ============================================================
// 敏感内存保护：mlock（禁 swap）+ zeroize（用后清零）
//
// 下载器会话凭据（酷狗 token/userid、网易 cookie）以 [MlockSecret] 存储：
// - mlock：页面锁定防被换出到磁盘（Linux/macOS 经 libc::mlock，
//   Windows 经 VirtualLock）；Linux 另设 MADV_DONTDUMP 防 core dump 拷贝。
// - zeroize：Drop / 重赋值时整块清零，防残留明文被静态途径读取。
//
// mlock 为**尽力而为**：RLIMIT_MEMLOCK 限制 / 权限不足 / 平台不支持时
// 自动降级为普通堆分配（不阻塞登录与下载），zeroize 兜底保证清零目标。
// ============================================================

use std::alloc::{alloc_zeroed, dealloc, Layout};
use std::ptr;

/// 页对齐大小（mlock 按整页生效；分配向上取整到该值）。
const PAGE: usize = 4096;

/// mlock + zeroize 的敏感缓冲（容量自适应；重赋值/登出时自动清零旧内容）。
pub struct MlockSecret {
    ptr: *mut u8,
    len: usize,
    cap: usize,
    locked: bool,
}

// SAFETY: MlockSecret 仅经 GLOBAL 互斥锁访问，指针独占管理、无并发别名；
// 跨线程传递（Mutex<T> 要求 T: Send，Lazy<Mutex<T>> 要求 T: Sync）依赖此保证。
unsafe impl Send for MlockSecret {}
unsafe impl Sync for MlockSecret {}

impl MlockSecret {
    /// 空缓冲（不分配、不锁定；首次 [set] 惰性分配）。
    pub fn new() -> Self {
        Self { ptr: ptr::null_mut(), len: 0, cap: 0, locked: false }
    }

    /// 分配 [size] 字节并（尽力）锁定。返回 (指针, 容量, 是否锁定)。
    ///
    /// 使用 [alloc_zeroed] 分配即清零：未写入区域恒为零（mlock 页若复用系统
    /// 内存可能含其他进程残留数据，清零防泄露；同时保证收缩写入后旧尾部外
    /// 区域不残留本对象旧值，overwrite_clears_old_content 不变量成立）。
    fn alloc_locked(size: usize) -> (*mut u8, usize, bool) {
        if size == 0 {
            return (ptr::null_mut(), 0, false);
        }
        let cap = size.div_ceil(PAGE) * PAGE;
        // SAFETY: cap > 0，align 1，均为合法 Layout
        let layout = Layout::from_size_align(cap, 1).expect("MlockSecret layout");
        let p = unsafe { alloc_zeroed(layout) };
        if p.is_null() {
            return (ptr::null_mut(), 0, false);
        }
        let locked = unsafe { lock_region(p, cap) };
        (p, cap, locked)
    }

    /// 写入完整字节串（超容自动重分配；旧缓冲经 Drop 清零后释放）。
    pub fn set(&mut self, s: &str) {
        if s.is_empty() {
            self.clear();
            return;
        }
        if s.len() > self.cap {
            let (p, cap, locked) = Self::alloc_locked(s.len());
            if !p.is_null() {
                // 旧缓冲在此赋值前 drop → zeroize + munlock + dealloc
                *self = Self { ptr: p, len: 0, cap, locked };
            }
        }
        if self.ptr.is_null() {
            // 分配失败（罕见）：保持空，不写入半截明文
            return;
        }
        // 收缩写入：先清零旧尾部，防 len 缩短后残留明文（如 token 重设为更短值）
        if s.len() < self.len {
            unsafe {
                ptr::write_bytes(self.ptr.add(s.len()), 0, self.len - s.len());
            }
        }
        // SAFETY: 目标区域容量 >= s.len() 且未初始化读（只写）；源为 &str 借用
        unsafe {
            ptr::copy_nonoverlapping(s.as_ptr(), self.ptr, s.len());
        }
        self.len = s.len();
    }

    /// 读取当前内容（借用于锁定内存，不产生副本）。
    pub fn as_str(&self) -> &str {
        if self.ptr.is_null() || self.len == 0 {
            return "";
        }
        // SAFETY: 写入内容为合法 UTF-8（来自 &str 拷贝），len 为实际写入字节数
        unsafe { std::str::from_utf8_unchecked(std::slice::from_raw_parts(self.ptr, self.len)) }
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// 显式清零（Drop 亦自动清零；登出路径可显式调用）。
    pub fn clear(&mut self) {
        if !self.ptr.is_null() {
            // SAFETY: [ptr, ptr+cap) 为本对象独占分配，写入 0 安全
            unsafe { ptr::write_bytes(self.ptr, 0, self.cap) };
        }
        self.len = 0;
    }
}

impl Default for MlockSecret {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for MlockSecret {
    fn drop(&mut self) {
        self.clear();
        if !self.ptr.is_null() {
            unsafe {
                if self.locked {
                    unlock_region(self.ptr, self.cap);
                }
                let layout = Layout::from_size_align(self.cap, 1).expect("MlockSecret layout");
                dealloc(self.ptr, layout);
            }
            self.ptr = ptr::null_mut();
        }
    }
}

#[cfg(unix)]
unsafe fn lock_region(p: *mut u8, len: usize) -> bool {
    // Linux：标记不参与 core dump（MADV_DONTDUMP），防崩溃转储拷贝明文；
    // 其他平台（macOS/BSD）不提供等效 madvise 语义，忽略。
    #[cfg(target_os = "linux")]
    unsafe {
        libc::madvise(p as *mut libc::c_void, len, libc::MADV_DONTDUMP);
    }
    // 尽力而为：mlock 失败（RLIMIT_MEMLOCK 过小等）返回 false，由 zeroize 兜底
    unsafe { libc::mlock(p as *mut libc::c_void, len) == 0 }
}

#[cfg(unix)]
unsafe fn unlock_region(p: *mut u8, len: usize) {
    unsafe {
        libc::munlock(p as *mut libc::c_void, len);
    }
}

#[cfg(windows)]
unsafe fn lock_region(p: *mut u8, len: usize) -> bool {
    unsafe { windows_sys::Win32::System::Memory::VirtualLock(p as _, len) != 0 }
}

#[cfg(windows)]
unsafe fn unlock_region(p: *mut u8, len: usize) {
    unsafe {
        windows_sys::Win32::System::Memory::VirtualUnlock(p as _, len);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn as_bytes(s: &MlockSecret) -> &[u8] {
        unsafe { std::slice::from_raw_parts(s.ptr, s.len) }
    }

    #[test]
    fn new_is_empty() {
        let s = MlockSecret::new();
        assert!(s.is_empty());
        assert_eq!(s.as_str(), "");
    }

    #[test]
    fn set_read_roundtrip() {
        let mut s = MlockSecret::new();
        s.set("uid=123&token=abc\n中文字符");
        assert!(!s.is_empty());
        assert_eq!(s.as_str(), "uid=123&token=abc\n中文字符");
        // 未写入区域保持零（分配时未初始化？alloc 不保证零，此处只检查写入区）
        assert_eq!(as_bytes(&s), s.as_str().as_bytes());
    }

    #[test]
    fn reset_realloc_keeps_new_value() {
        let mut s = MlockSecret::new();
        s.set("short");
        s.set("a much longer secret value that exceeds the first allocation");
        assert_eq!(s.as_str(), "a much longer secret value that exceeds the first allocation");
        // 再次缩短：容量保留，内容正确覆盖
        s.set("tiny");
        assert_eq!(s.as_str(), "tiny");
    }

    #[test]
    fn clear_zeroes_memory() {
        let mut s = MlockSecret::new();
        s.set("sensitive-payload");
        assert!(!as_bytes(&s).is_empty());
        s.clear();
        assert!(s.is_empty());
        assert_eq!(s.as_str(), "");
        // 整个容量区域必须被清零（clear 按 cap 清零）
        let cap = s.cap;
        unsafe {
            let slice = std::slice::from_raw_parts(s.ptr, cap);
            assert!(slice.iter().all(|&b| b == 0));
        }
    }

    #[test]
    fn set_empty_clears() {
        let mut s = MlockSecret::new();
        s.set("secret");
        s.set("");
        assert!(s.is_empty());
        assert_eq!(s.as_str(), "");
    }

    #[test]
    fn overwrite_clears_old_content() {
        // 长 → 短：旧尾部残留必须清零（len 收缩，剩余 cap 仍应全零）
        let mut s = MlockSecret::new();
        s.set("abcdefghijklmnopqrstuvwxyz");
        let cap = s.cap;
        s.set("abc");
        assert_eq!(s.as_str(), "abc");
        unsafe {
            let slice = std::slice::from_raw_parts(s.ptr, cap);
            assert_eq!(&slice[..3], b"abc");
            assert!(slice[3..].iter().all(|&b| b == 0));
        }
    }

    #[test]
    fn mlock_is_best_effort_no_panic() {
        // mlock 受 RLIMIT_MEMLOCK/权限影响，成功与否都不应影响语义
        let mut s = MlockSecret::new();
        s.set("whatever");
        assert_eq!(s.as_str(), "whatever");
        drop(s);
        // 释放后无 panic 即通过
    }
}
