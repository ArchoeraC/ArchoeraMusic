#!/usr/bin/env bash
# ArchoeraMusic vault（Rust）Windows 目标端到端测试（msvc-wine + Wine）。
#
# 覆盖（全部在 Wine 上用真实 Windows 产物运行）：
#   1. 构建标记（TEST）+ 各模式 init/status/serve/destroy（crypto 默认 DPAPI / file /
#      m1 / m2a / m2b）+ 错误口令与退避锁定 + KDF 强度与 set-kdf 重键 + 越界拒绝
#   2. 打包布局血缘校验（`<dir>/native/<vault>` + `<dir>/archoera_music.exe`）：
#      预期主程序 spawn → 放行；非预期主程序 → 拒绝；大小写不敏感比较
#   3. 会话超时语义（C# `ReadLineAsync().WaitAsync(s)` 对齐）：握手 10s、空闲 30s 自退、
#      set 负载 30s；父进程消失后空闲超时兜底自退
#   4. 健壮性：畸形/超长输入、非 UTF-8 负载、并发多会话（完成后稳定断言）、
#      destroy 全量清理、退避状态篡改
#   5. 跨 OS / 跨实现：Windows(Wine) 写 → Linux Rust 读 / Linux C#(NativeAOT) 读
#
# 依赖：wine（含 winepath）、LLVM lld-link、msvc-wine 布局的 MSVC + Windows SDK
#       （默认 /opt/msvc，可用 MSVC_ROOT 覆盖）、rustup target x86_64-pc-windows-msvc、
#       python3。缺任一依赖 → 打印跳过原因并以 0 退出（可选交叉验证）。
#
# 用法：./test-windows.sh
set -euo pipefail
cd "$(dirname "$0")"

MSVC_ROOT="${MSVC_ROOT:-/opt/msvc}"
RUSTUP="${RUSTUP:-rustup}"

skip() { echo "[test-windows] 跳过：$*" >&2; exit 0; }
command -v wine >/dev/null 2>&1 || skip "未检测到 wine"
command -v winepath >/dev/null 2>&1 || skip "未检测到 winepath"
command -v lld-link >/dev/null 2>&1 || skip "未检测到 lld-link（LLVM）"
command -v python3 >/dev/null 2>&1 || skip "未检测到 python3"
[ -d "$MSVC_ROOT/VC/Tools/MSVC" ] || skip "未检测到 msvc-wine 布局（MSVC_ROOT=$MSVC_ROOT）"

MSVC_VER="$(ls "$MSVC_ROOT/VC/Tools/MSVC" | sort -V | tail -1)"
SDK_VER="$(ls "$MSVC_ROOT/Windows Kits/10/Lib" | sort -V | tail -1)"
export LIB="$MSVC_ROOT/VC/Tools/MSVC/$MSVC_VER/lib/x64;$MSVC_ROOT/Windows Kits/10/Lib/$SDK_VER/um/x64;$MSVC_ROOT/Windows Kits/10/Lib/$SDK_VER/ucrt/x64"
export WINEDEBUG="${WINEDEBUG:--all}"

"$RUSTUP" target add x86_64-pc-windows-msvc >/dev/null 2>&1 || true

# ── 构建 Windows 测试产物（crt-static，与 build_windows.bat 同参数）──────
echo "[test-windows] 构建 x86_64-pc-windows-msvc 测试产物…"
RUSTFLAGS="-C linker=lld-link -C target-feature=+crt-static" \
  cargo build --release --target x86_64-pc-windows-msvc --features vault_testing
mkdir -p build
cp target/x86_64-pc-windows-msvc/release/archoera-vault.exe build/archoera-vault-test.exe

# ── 构建血缘校验探针（扮演「预期主程序」，零依赖 crate，可离线构建）──────
PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "$PROBE_DIR" build/probe-parent.exe' EXIT
mkdir -p "$PROBE_DIR/src"
cat > "$PROBE_DIR/Cargo.toml" <<'TOML'
[package]
name = "probe-parent"
version = "0.1.0"
edition = "2021"
[[bin]]
name = "probe-parent"
path = "src/main.rs"
[profile.release]
panic = "abort"
strip = true
TOML
cat > "$PROBE_DIR/src/main.rs" <<'RS'
// 以「预期主程序」身份 spawn <自身目录>/native/archoera-vault-test.exe，
// argv/stdio 原样透传（serve 行协议可直接在管道上对话）。
use std::process::{exit, Command};

fn main() {
    let exe = std::env::current_exe().expect("current_exe");
    let dir = exe.parent().expect("parent").to_path_buf();
    let child = dir.join("native").join("archoera-vault-test.exe");
    let args: Vec<String> = std::env::args().skip(1).collect();
    let status = Command::new(&child).args(&args).status().expect("spawn child");
    exit(status.code().unwrap_or(1));
}
RS
echo "[test-windows] 构建血缘探针…"
( cd "$PROBE_DIR" && RUSTFLAGS="-C linker=lld-link -C target-feature=+crt-static" \
    cargo build --release --target x86_64-pc-windows-msvc --quiet )
cp "$PROBE_DIR/target/x86_64-pc-windows-msvc/release/probe-parent.exe" build/probe-parent.exe

# ── Linux 侧产物（跨 OS 对照）与黄金夹具 ────────────────────────────────
./build-test.sh >/dev/null
LINUX_BIN="$PWD/build/archoera-vault-test"
TESTDATA="$PWD/testdata"        # 黄金夹具（C# 活体 oracle 已删除，见 testdata/README.md）

echo "[test-windows] 运行 Wine 端到端（wine $(wine --version 2>/dev/null) / MSVC $MSVC_VER / SDK $SDK_VER）"
python3 - "$PWD/build/archoera-vault-test.exe" "$PWD/build/probe-parent.exe" "$LINUX_BIN" "$TESTDATA" <<'PY'
# -*- coding: utf-8 -*-
"""Wine 端到端断言。argv: <vault.exe> <probe.exe> <linux-bin> <testdata>"""
import base64, json, os, select, shutil, subprocess, sys, tempfile, time

EXE, PROBE, LINUX_BIN = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[3])
TESTDATA = os.path.abspath(sys.argv[4])

ENV = dict(os.environ, WINEDEBUG=os.environ.get("WINEDEBUG", "-all"))
WORK = tempfile.mkdtemp(prefix="vault-win-")
V = os.path.join(WORK, "archoera-vault-test.exe")
shutil.copy2(EXE, V)          # ASCII 路径副本：cmd 对中文/空格路径易受代码页干扰
shutil.copy2(PROBE, os.path.join(WORK, "probe-parent.exe"))

fails, passes = [], []


def check(name, cond, detail=""):
    (passes if cond else fails).append(name if cond else "%s :: %s" % (name, detail))
    print(("  \u2713 " if cond else "  \u2717 ") + name + ("" if cond else " :: %s" % (detail,)))


def winpath(p):
    return subprocess.run(["winepath", "-w", p], stdout=subprocess.PIPE, env=ENV,
                          check=True).stdout.decode().strip()


def run(*args, stdin_data=None, timeout=600):
    """经 cmd /c 运行：Windows 侧父进程为 cmd.exe，血缘校验才拿得到父 pid
    （Unix 侧 wine 直启时 Wine 不回填 InheritedFromUniqueProcessId）。"""
    p = subprocess.run(["wine", "cmd", "/c", winpath(V), *args], input=stdin_data,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV, timeout=timeout)
    return p.returncode, p.stdout.decode(errors="replace").strip(), p.stderr.decode(errors="replace")


class Serve:
    def __init__(self, data):
        self.p = subprocess.Popen(["wine", "cmd", "/c", winpath(V), "serve", winpath(data)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=ENV)

    def send_raw(self, data):
        self.p.stdin.write(data)
        self.p.stdin.flush()

    def line(self):
        return self.p.stdout.readline().decode(errors="replace").rstrip("\n")

    def cmd(self, line, payload=None):
        self.send_raw((line + "\n" + (payload + "\n" if payload is not None else "")).encode())
        return self.line()

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        return self.p.wait(timeout=90)


def ls(d):
    return sorted(os.listdir(d))


def b64(b):
    return base64.b64encode(b.encode() if isinstance(b, str) else b).decode()


def newdir(prefix="vw-"):
    return tempfile.mkdtemp(prefix=prefix, dir=WORK)


B32, B16 = b64(os.urandom(32)), b64(os.urandom(16))
SECRET = b64("win-机密-secret-跨OS".encode())
M1_PW, M2A_PW = "p@ss-口令-m1", "dev-口令-m2a"

print("== 0. 构建标记与内存护栏 ==")
rc, out, _ = run("--version")
check("--version 报 TEST 标记", rc == 0 and out.startswith("ARCHOERA-VAULT-TEST-"), out)
rc, out, _ = run("selftest-mem")
check("memguard：VirtualLock 生效（locked=true）", rc == 0 and "locked=true" in out, out)

print("== 1. crypto（默认后端 = DPAPI，密文落 sshare.bin）==")
d = newdir()
rc, out, err = run("init-crypto", winpath(d))
check("init-crypto ok", rc == 0 and out.startswith("ok "), "rc=%s %r %r" % (rc, out, err))
check("产物 = vault + sshare.bin(+.bak)",
      {"credentials.vault", "sshare.bin"} <= set(ls(d)) <=
      {"credentials.vault", "credentials.vault.bak", "sshare.bin", "vault.lock"}, ls(d))
ssh = open(os.path.join(d, "sshare.bin"), "rb").read()
check("sshare.bin 为 DPAPI 密文（非 32B 明文份额）", len(ssh) != 32 and len(ssh) > 64, len(ssh))
rc, out, _ = run("status", winpath(d))
check("status mode=crypto", '"mode":"crypto"' in out, out)
s = Serve(d)
r = s.cmd("handshake %s %s" % (B32, B16))
check("免密握手（DPAPI 解封授权份额）", r.startswith("ok handshake"), r)
check("握手尾字段 = TEST 标记", r.endswith("ARCHOERA-VAULT-TEST-v1"), r)
check("set/get/delete 往返", s.cmd("set kugou:session", SECRET) == "ok"
      and s.cmd("get kugou:session") == "ok " + SECRET
      and s.cmd("delete kugou:session") == "ok true"
      and s.cmd("get kugou:session") == "ok null")
check("quit + 退出码 0", s.cmd("quit") == "ok" and s.close() == 0)
raw = open(os.path.join(d, "credentials.vault"), "rb").read()
check("vault 磁盘无明文", "win-".encode() not in raw and b"\xe6\x9c\xba\xe5\xaf\x86" not in raw)
rc, out, _ = run("destroy", winpath(d))
check("destroy 全量清理（仅留跨进程锁文件 vault.lock）",
      rc == 0 and out.startswith("ok") and ls(d) == ["vault.lock"], "%r %s" % (out, ls(d)))
shutil.rmtree(d, ignore_errors=True)

print("== 2. init-file（file 后端，可跨 OS 迁移）==")
d_file = newdir()
rc, out, err = run("init-file", winpath(d_file), "--key-stdin", stdin_data=os.urandom(32).hex().encode() + b"\n")
check("init-file ok", rc == 0 and out.startswith("ok "), "%r %r" % (out, err))
check("secret.key 落盘", "secret.key" in ls(d_file), ls(d_file))
s = Serve(d_file)
check("握手 + 写入跨 OS 条目", s.cmd("handshake %s %s" % (B32, B16)).startswith("ok handshake")
      and s.cmd("set cross:os", SECRET) == "ok" and s.cmd("get cross:os") == "ok " + SECRET)
s.cmd("quit")
check("退出码 0", s.close() == 0)

print("== 3. slots m1（口令自包含）==")
d_m1 = newdir()
rc, out, err = run("init-m1", winpath(d_m1), stdin_data=(M1_PW + "\n").encode())
check("init-m1 ok", rc == 0 and out.startswith("ok "), "%r %r" % (out, err))
check("自包含（无 sshare.bin/secret.key/device.key）",
      set(ls(d_m1)) <= {"credentials.vault", "credentials.vault.bak", "vault.lock"}, ls(d_m1))
s = Serve(d_m1)
check("口令握手 + 写入跨 OS 条目", s.cmd("handshake %s %s %s" % (B32, B16, b64(M1_PW))).startswith("ok handshake")
      and s.cmd("set cross:os", SECRET) == "ok")
s.cmd("quit"); s.close()
s = Serve(d_m1)
check("错误口令 → SHARE_MISMATCH", s.cmd("handshake %s %s %s" % (B32, B16, b64("wrong"))).startswith("err SHARE_MISMATCH"))
check("握手失败即退出（退出码 1）", s.close() == 1)
s = Serve(d_m1)
r = s.cmd("handshake %s %s %s" % (B32, B16, b64(M1_PW)))
check("失败后立即重试 → 退避锁定（连尝试都不做）", r.startswith("err") and "锁定" in r, r)
s.close()
time.sleep(1.4)
s = Serve(d_m1)
check("退避到期后正确口令可解锁", s.cmd("handshake %s %s %s" % (B32, B16, b64(M1_PW))).startswith("ok handshake"))
s.cmd("quit"); s.close()
check("成功解锁后 vault.lockout 已清除", "vault.lockout" not in ls(d_m1), ls(d_m1))

print("== 4. slots m2a（口令+设备+恢复码）==")
d_m2a = newdir()
rc, out, err = run("init-m2a", winpath(d_m2a), stdin_data=(M2A_PW + "\n").encode())
check("init-m2a ok = ok <锚点> <恢复码>", rc == 0 and out.startswith("ok ") and len(out.split()) == 3, "%r %r" % (out, err))
check("device.key 落盘", "device.key" in ls(d_m2a), ls(d_m2a))
code = out.split()[2] if len(out.split()) >= 3 else ""
if code:
    s = Serve(d_m2a)
    check("口令+设备解锁", s.cmd("handshake %s %s %s" % (B32, B16, b64(M2A_PW))).startswith("ok handshake"))
    check("m2a 写入跨 OS 条目", s.cmd("set cross:os", SECRET) == "ok")
    s.cmd("quit"); s.close()
    os.rename(os.path.join(d_m2a, "device.key"), os.path.join(d_m2a, "device.key.off"))
    s = Serve(d_m2a)
    r = s.cmd("handshake %s %s %s" % (B32, B16, b64(M2A_PW)))
    check("缺 device.key → NEED_RECOVERY", "NEED_RECOVERY" in r, r)
    s.close()
    s = Serve(d_m2a)
    r = s.cmd("handshake %s %s %s %s" % (B32, B16, b64(code), b64("rec")))
    check("恢复码解锁（rec 标签）+ 读同值", r.startswith("ok handshake") and s.cmd("get cross:os") == "ok " + SECRET, r)
    s.cmd("quit"); s.close()
    s = Serve(d_m2a)
    check("m2a 标签非 rec 被拒",
          s.cmd("handshake %s %s %s %s" % (B32, B16, b64(code), b64("x"))).startswith("err"))
    s.close()
    os.rename(os.path.join(d_m2a, "device.key.off"), os.path.join(d_m2a, "device.key"))

print("== 5. slots m2b（仅设备）==")
d_m2b = newdir()
rc, out, err = run("init-m2b", winpath(d_m2b))
check("init-m2b ok", rc == 0 and out.startswith("ok "), "%r %r" % (out, err))
s = Serve(d_m2b)
check("handshake <H> <C> + 写入跨 OS 条目", s.cmd("handshake %s %s" % (B32, B16)).startswith("ok handshake")
      and s.cmd("set cross:os", SECRET) == "ok" and s.cmd("get cross:os") == "ok " + SECRET)
s.cmd("quit"); s.close()
os.rename(os.path.join(d_m2b, "device.key"), os.path.join(d_m2b, "device.key.off"))
s = Serve(d_m2b)
check("缺 device.key → 拒绝", s.cmd("handshake %s %s" % (B32, B16)).startswith("err"))
s.close()
os.rename(os.path.join(d_m2b, "device.key.off"), os.path.join(d_m2b, "device.key"))

print("== 6. KDF 强度 + set-kdf 重键（m1）+ 越界拒绝 ==")
d_kdf = newdir()
rc, out, err = run("init-m1", winpath(d_kdf), "--kdf-m", "32768", "--kdf-t", "3", "--kdf-p", "1",
                   stdin_data=(M1_PW + "\n").encode())
check("init-m1 --kdf-* ok", rc == 0 and out.startswith("ok "), "%r %r" % (out, err))
s = Serve(d_kdf)
check("重键前 set", s.cmd("handshake %s %s %s" % (B32, B16, b64(M1_PW))).startswith("ok")
      and s.cmd("set x:y", SECRET) == "ok")
s.cmd("quit"); s.close()
rc, out, err = run("set-kdf", winpath(d_kdf), "--kdf-m", "131072", "--kdf-t", "4", "--kdf-p", "1",
                   stdin_data=(M1_PW + "\n").encode())
check("set-kdf 重键 ok", rc == 0 and out.startswith("ok"), "%r %r" % (out, err))
s = Serve(d_kdf)
check("重键后数据仍在", s.cmd("handshake %s %s %s" % (B32, B16, b64(M1_PW))).startswith("ok")
      and s.cmd("get x:y") == "ok " + SECRET)
s.cmd("quit"); s.close()
d_bad = newdir()
rc, out, _ = run("init-m1", winpath(d_bad), "--kdf-m", "99999999", stdin_data=b"p\n")
check("--kdf-m 越界快速拒绝", rc == 1 and out.startswith("err"), out)

print("== 7. 打包布局血缘校验（native/ + 预期主程序）==")
PKG = newdir("pkg-")
os.makedirs(os.path.join(PKG, "native"), exist_ok=True)
shutil.copy2(V, os.path.join(PKG, "native", "archoera-vault-test.exe"))
shutil.copy2(os.path.join(WORK, "probe-parent.exe"), os.path.join(PKG, "archoera_music.exe"))
shutil.copy2(os.path.join(WORK, "probe-parent.exe"), os.path.join(PKG, "other.exe"))
run("init-crypto", winpath(PKG))


def spawn_handshake(parent_exe):
    p = subprocess.Popen(["wine", "cmd", "/c", parent_exe, "serve", winpath(PKG)],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV)
    p.stdin.write(("handshake %s %s\n" % (B32, B16)).encode()); p.stdin.flush()
    line = p.stdout.readline().decode(errors="replace").rstrip("\n")
    p.stdin.close()
    try:
        p.wait(timeout=60)
    except subprocess.TimeoutExpired:
        p.kill()
    return line


line = spawn_handshake(winpath(os.path.join(PKG, "archoera_music.exe")))
check("预期主程序 spawn → 放行", line.startswith("ok handshake"), line)
line = spawn_handshake(winpath(os.path.join(PKG, "archoera_music.exe")).upper())
check("全大写路径 → 放行（大小写不敏感比较）", line.startswith("ok handshake"), line)
line = spawn_handshake(winpath(os.path.join(PKG, "other.exe")))
check("非预期主程序 spawn → 拒绝", line.startswith("err") and "主程序" in line, line)

print("== 8. 会话超时（C# ReadLineAsync().WaitAsync 语义）==")
d_to = newdir()
run("init-m1", winpath(d_to), stdin_data=(M1_PW + "\n").encode())


def spawn_serve(data):
    return subprocess.Popen(["wine", "cmd", "/c", winpath(V), "serve", winpath(data)],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV)


p = spawn_serve(d_to)
t0 = time.time()
try:
    p.wait(timeout=30); exited = True
except subprocess.TimeoutExpired:
    exited = False; p.kill()
dt = time.time() - t0
check("握手 10s 超时（不发送任何行）", exited and dt < 25, "%.1fs" % dt)

p = spawn_serve(d_to)
p.stdin.write(("handshake %s %s %s\n" % (B32, B16, b64(M1_PW))).encode()); p.stdin.flush()
check("空闲探针握手成功", p.stdout.readline().decode().startswith("ok handshake"))
t0 = time.time()
try:
    p.wait(timeout=60); exited = True
except subprocess.TimeoutExpired:
    exited = False; p.kill()
dt = time.time() - t0
check("空闲 30s 自退（父进程存活但无输入）", exited and dt < 45, "%.1fs" % dt)

p = spawn_serve(d_to)
p.stdin.write(("handshake %s %s %s\n" % (B32, B16, b64(M1_PW))).encode()); p.stdin.flush()
p.stdout.readline()
p.stdin.write(b"set k:v\n"); p.stdin.flush()   # 故意不发负载行
readable, _, _ = select.select([p.stdout], [], [], 45)
line = p.stdout.readline().decode(errors="replace").strip() if readable else ""
check("set 负载超时 → err（不挂死）", "超时" in line, line)
p.kill(); p.wait(timeout=30)

print("== 9. 健壮性（畸形输入 / 并发多会话 / destroy / 退避篡改）==")
d_rob = newdir()
run("init-m1", winpath(d_rob), stdin_data=(M1_PW + "\n").encode())
s = Serve(d_rob)
s.cmd("handshake %s %s %s" % (B32, B16, b64(M1_PW)))
check("超长握手字段 → 拒绝", s.cmd("handshake %s %s %s" % (b64(b"A" * 1024 * 1024), B16, b64(M1_PW))).startswith("err"))
check("非法 base64 握手 → 拒绝", s.cmd("handshake %s !!x!! %s" % (B32, b64(M1_PW))).startswith("err"))
check("字段数不足 → 拒绝", s.cmd("handshake %s" % B32).startswith("err"))
s.close()
s = Serve(d_rob)
s.cmd("handshake %s %s %s" % (B32, B16, b64(M1_PW)))
check("保留 uid __auth__ 拒绝写入（读负载前即拒，与 C# 同）", s.cmd("set __auth__").startswith("err"))
check("未知命令 → err 且会话继续", s.cmd("bogus x").startswith("err") and s.cmd("get nope") == "ok null")
check("非法 base64 负载 → err 且会话继续",
      s.cmd("set k:v", "!!!not base64!!!").startswith("err") and s.cmd("get k:v") == "ok null")
s.send_raw(b"set bin:v\n\xff\xfe\xfd\n")
check("非 UTF-8 负载行 → err（会话继续，与 unix/C# 宽松解码一致）",
      s.line().startswith("err") and s.cmd("get bin:v") == "ok null")
big = b64(os.urandom(1024 * 1024))
check("1MiB 负载 set/get 往返", s.cmd("set big:v", big) == "ok" and s.cmd("get big:v") == "ok " + big)
check("空行 → err 且会话继续", s.cmd("").startswith("err"))
check("quit 正常退出", s.cmd("quit") == "ok" and s.close() == 0)

# 专用会话固化「`set __auth__` 带负载行」的协议细节：拒绝发生在读取负载之前，
# 该负载行滞留为下一条命令（客户端整体滞后一行）。Dart 侧永不使用保留 uid，
# 故仅作行为固化（与 C# HandleSet 同源顺序）。
q = Serve(d_rob)
q.cmd("handshake %s %s %s" % (B32, B16, b64(M1_PW)))
r1 = q.cmd("set __auth__", SECRET)
r2 = q.cmd("probe:sync")           # 不被当作命令：vault 先回应滞留的负载行
check("带负载的 set __auth__ 拒绝写入且负载行滞留（与 C# 同）",
      r1.startswith("err") and r2.startswith("err 未知命令"), "%r %r" % (r1, r2))
q.close()

d_conc = newdir()
run("init-m1", winpath(d_conc), stdin_data=(M1_PW + "\n").encode())
a, b = Serve(d_conc), Serve(d_conc)
check("并发两会话均握手成功", a.cmd("handshake %s %s %s" % (B32, B16, b64(M1_PW))).startswith("ok handshake")
      and b.cmd("handshake %s %s %s" % (B32, B16, b64(M1_PW))).startswith("ok handshake"))
VA, VB = b64(b"from-A"), b64(b"from-B")
check("两会话各自写入", a.cmd("set uid:a", VA) == "ok" and b.cmd("set uid:b", VB) == "ok")
a.cmd("quit"); b.cmd("quit")
check("两会话均正常退出", a.close() == 0 and b.close() == 0)
check("无 .tmp 残留（原子写）", [f for f in ls(d_conc) if f.endswith(".tmp")] == [], ls(d_conc))
c = Serve(d_conc)
hs = c.cmd("handshake %s %s %s" % (B32, B16, b64(M1_PW)))
check("并发写后库仍可解锁（未损坏）", hs.startswith("ok handshake"), hs)
ga, gb = c.cmd("get uid:a"), c.cmd("get uid:b")
check("至少一个并发写生效且无半写",
      (ga in ("ok " + VA, "ok null")) and (gb in ("ok " + VB, "ok null")) and not (ga == "ok null" and gb == "ok null"),
      "%r %r" % (ga, gb))
c.cmd("quit"); c.close()

for mode, args, stdin_data in (("crypto", ["init-crypto"], None),
                               ("m1", ["init-m1"], (M1_PW + "\n").encode()),
                               ("m2a", ["init-m2a"], (M1_PW + "\n").encode()),
                               ("m2b", ["init-m2b"], None)):
    d_d = newdir()
    rc, out, _ = run(*args, winpath(d_d), stdin_data=stdin_data)
    rc2, out2, _ = run("destroy", winpath(d_d))
    check("%s: destroy 后只剩 vault.lock" % mode,
          rc == 0 and rc2 == 0 and out2.startswith("ok") and ls(d_d) == ["vault.lock"],
          "%r %s" % (out2, ls(d_d)))
    shutil.rmtree(d_d, ignore_errors=True)

d_lk = newdir()
run("init-m1", winpath(d_lk), stdin_data=(M1_PW + "\n").encode())
open(os.path.join(d_lk, "vault.lockout"), "w").write("10 999999999999999")
s = Serve(d_lk)
r = s.cmd("handshake %s %s %s" % (B32, B16, b64(M1_PW)))
check("远期 until 篡改 → 锁死（与 C# 同：本地写权限＝可 DoS）", "锁定" in r, r)
s.close()
open(os.path.join(d_lk, "vault.lockout"), "w").write("garbage")
s = Serve(d_lk)
check("损坏 lockout → 视为无锁定（可解锁）", s.cmd("handshake %s %s %s" % (B32, B16, b64(M1_PW))).startswith("ok handshake"))
s.cmd("quit"); s.close()

print("== 10. 跨 OS：Windows(Wine) 写 → Linux Rust 读 ==")


def linux_read(bin_, data, pw=None, code=None, backend_file=False):
    env = dict(os.environ)
    if backend_file:
        env["ARCHOERA_VAULT_BACKEND"] = "file"
    p = subprocess.Popen([bin_, "serve", data], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env)
    fields = [B32, B16]
    if pw is not None:
        fields.append(b64(pw))
    if code is not None:
        fields += [b64(code), b64("rec")]
    p.stdin.write((" ".join(["handshake", *fields]) + "\n").encode())
    p.stdin.write(b"get cross:os\nquit\n"); p.stdin.flush()
    hs = p.stdout.readline().decode().rstrip("\n")
    got = p.stdout.readline().decode().rstrip("\n")
    p.wait(timeout=90)
    return hs, got


for name, data, kw in (("m1（口令）", d_m1, {"pw": M1_PW}),
                       ("m2b（设备）", d_m2b, {}),
                       ("m2a（口令+设备）", d_m2a, {"pw": M2A_PW}),
                       ("file 后端", d_file, {"backend_file": True})):
    hs, got = linux_read(LINUX_BIN, data, **kw)
    check("Linux Rust 解 Windows 库读同值：%s" % name, hs.startswith("ok handshake") and got == "ok " + SECRET,
          "%r %r" % (hs, got))
print("== 11. 跨 OS：Windows(Wine) 读 Linux 生成的黄金夹具（字节兼容锚点）==")


def fixture_read(name):
    """夹具复制到 Wine 可见目录后，用 Windows 产物解锁并读回固定值。"""
    src = os.path.join(TESTDATA, name)
    meta = json.load(open(os.path.join(src, "unlock.json")))
    d = os.path.join(WORK, "fixture-" + name)
    shutil.copytree(src, d, dirs_exist_ok=True)
    s = Serve(d)
    if meta["mode"] in ("m1", "m2a"):
        fields = [B32, B16, b64(meta["password"])]
    else:  # crypto（免密）/ m2b（仅设备）
        fields = [B32, B16]
    r = s.cmd("handshake " + " ".join(fields))
    got = {}
    for uid in meta["entries"]:
        line = s.cmd("get " + uid)
        got[uid] = None if line == "ok null" else base64.b64decode(line.split(" ", 1)[1]).decode()
    s.cmd("quit"); s.close()
    return meta, r, got


for name in ("crypto-file", "m1", "m2a", "m2b"):
    meta, r, got = fixture_read(name)
    check("Windows 读 Linux 夹具：%s（%s）" % (name, meta["mode"]),
          r.startswith("ok handshake") and got == meta["entries"], "%r %r" % (r[:40], got))

shutil.rmtree(WORK, ignore_errors=True)
print()
print("通过 %d 项" % len(passes) + ("，失败 %d 项" % len(fails) if fails else ""))
for f in fails:
    print("  \u2717 " + f)
sys.exit(1 if fails else 0)
PY

echo "[test-windows] 全部通过 ✔"
