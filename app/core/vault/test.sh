#!/usr/bin/env bash
# vault（凭据保险库）冒烟测试：对 NativeAOT 产物做端到端验证。
#
# 覆盖（serve 会话协议，credential-vault-plan §3.7/§3.8）：
#   1. init 返回会话锚点 T；status 已初始化
#   2. serve 会话全链路：血缘白名单 → 握手（HMAC 验证 + 锚点回读）→
#      set/get/delete/status → quit
#   3. 独立运行拒绝：无白名单 / 白名单不含父进程 → err
#   4. 错误握手（格式/负载长度错误）→ err
#   5. 磁盘无明文（vault 文件与份额文件均不含明文串）
#   6. 仅 vault 侧份额无法解密（删 S → 握手即 err，fail-closed）
#   7. 密文篡改被 GCM 认证拦截（改 1 字节 → 握手 err）
#   8. 崩溃联动前提：会话中被 SIGSEGV → 父进程观察到非零（信号）退出
#   9. destroy 后 status 未初始化、vault 文件删除
#  10. selftest（Argon2id 自检，RFC 9106 向量）
#  11. 口令模式全链路：init-password → 带口令握手 → set/get/quit
#  12. 错误口令锁定退避 + 锁定期间拒绝（连尝试都不做）+ 退避后恢复
#
# 说明：使用测试构建 build/archoera-vault-test（VAULT_TESTING 条件编译，含
# InsecureFileStore 测试明文存储）——headless CI 无 D-Bus Secret Service，真实
# 平台存储（DPAPI/Keychain/libsecret）须在对应平台手动验证。
# 生产二进制 build.sh 产物（archoera-vault）不含明文存储逻辑，本测试不用它。
set -euo pipefail
cd "$(dirname "$0")"

VAULT="build/archoera-vault-test"
[ -x "$VAULT" ] || { echo "缺少测试产物，先运行 ./build-test.sh" >&2; exit 1; }

# 条件编译自检：测试产物须为 TEST 标记（非生产 PROD）——确保 build-test.sh 的
# VAULT_TESTING 生效；生产 build.sh 产物不含明文存储分支（README 安全说明可查证）
case "$("$VAULT" --version)" in
  ARCHOERA-VAULT-TEST-*) : ;;
  *) echo "测试产物标记异常（非 TEST），重新运行 ./build-test.sh" >&2; exit 1;;
esac

export ARCHOERA_VAULT_INSECURE_FILE_STORE=1
DATA="$(mktemp -d)"
DATA2="$(mktemp -d)"
DATA3="$(mktemp -d)"
trap 'rm -rf "$DATA" "$DATA2" "$DATA3"' EXIT

PASS="S3cr3t-P@ssword-酷狗"
B64=$(printf '%s' "$PASS" | base64 -w0)
UID1="kugou:session"
UID2="netease:cookie"
# 白名单声明测试父进程（bash 管道 / python3 驱动两种 spawn 方式均可）
export ARCHOERA_VAULT_PARENT_OK="bash,sh,python3"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }

# vault 命令错误时退出码为 1，pipefail 下会污染管道状态；这里吞掉退出码，
# 仅以 stdout 内容为准（err/ok 前缀由调用方断言）。
run() { "$VAULT" "$@" 2>&1 || true; }

# ── 1. init/status/destroy（CLI，不经血缘校验）────────────────────
ANCHOR=$(run init "$DATA")
case "$ANCHOR" in
  ok\ *) [ -n "${ANCHOR#ok }" ] || fail "init 应返回非空锚点";;
  *) fail "init 失败: $ANCHOR";;
esac
[ -f "$DATA/credentials.vault" ] || fail "init 应生成 credentials.vault"
run status "$DATA" | grep -q '"initialized":true' || fail "status 应为已初始化"
pass "init 返回会话锚点 + status 已初始化"

# ── 2. serve 会话全链路（python3 驱动）──────────────────────────────
python3 - "$VAULT" "$DATA" "$B64" "$UID1" "$UID2" <<'PY' || fail "serve 会话链路失败"
import base64, hashlib, hmac, os, subprocess, sys

vault, data, b64, uid1, uid2 = sys.argv[1:6]
env = dict(os.environ)
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)

def cmd(line, payload=None):
    if payload is None:
        p.stdin.write((line + "\n").encode())
    else:
        p.stdin.write((line + "\n" + payload + "\n").encode())
    p.stdin.flush()
    return p.stdout.readline().decode().rstrip("\n")

# 握手：H=32B 会话密钥，C=16B challenge；应答须含锚点 T + HMAC-SHA256(H, C) + 构建标记
h, c = os.urandom(32), os.urandom(16)
hb = base64.b64encode(h).decode()
cb = base64.b64encode(c).decode()
resp = cmd("handshake %s %s" % (hb, cb))
parts = resp.split(" ")
assert parts[:2] == ["ok", "handshake"], "握手应答异常: %r" % resp
t = base64.b64decode(parts[2])
mac = base64.b64decode(parts[3])
assert len(t) == 16, "锚点应 16B"
assert mac == hmac.new(h, c, hashlib.sha256).digest(), "HMAC-SHA256 校验失败"
# 第 5 字段 = 构建标记（版本指纹）：测试构建须上报 TEST 标记（生产为 PROD）
assert parts[4].startswith("ARCHOERA-VAULT-TEST"), "握手应上报 TEST 构建标记: %r" % resp

# set（负载走 stdin 第二行）/ get / delete / status / quit
assert cmd("set %s" % uid1, b64) == "ok", "set 失败"
assert cmd("get %s" % uid1).startswith("ok "), "get 失败"
assert cmd("get %s" % uid1).split(" ", 1)[1] == b64, "get 回读不一致"
assert cmd("set %s" % uid2, base64.b64encode(b"another-secret").decode()) == "ok"
assert cmd("get %s" % uid2).startswith("ok "), "get 2 失败"
assert cmd("delete %s" % uid2) == "ok true", "delete 失败"
assert cmd("get %s" % uid2) == "ok null", "删除后应无条目"
assert cmd("status") == 'ok {"initialized":true}', "会话内 status 失败"
assert cmd("quit") == "ok", "quit 失败"
p.wait(timeout=5)
assert p.returncode == 0, "quit 后应正常退出，got %r" % p.returncode
print("ok")
PY
pass "serve 会话全链路（握手 HMAC + set/get/delete/quit）"

# ── 3. 独立运行拒绝（血缘白名单）────────────────────────────────────
# 说明：serve 拒绝路径退出码为 1，pipefail 下会污染管道状态，故用 $( ) 捕获 +
# `|| true` 吞掉退出码，仅以 stdout 内容（err/ok 前缀）为准。
OUT=$(printf 'handshake AAAA BBBB\n' \
  | env -u ARCHOERA_VAULT_PARENT_OK "$VAULT" serve "$DATA" 2>&1) || true
case "$OUT" in
  err*) : ;;
  *) fail "无白名单应拒绝独立运行（got: $OUT）";;
esac
pass "独立运行拒绝（无父进程白名单）"

OUT=$(printf 'handshake AAAA BBBB\n' \
  | ARCHOERA_VAULT_PARENT_OK=definitely-not-our-parent "$VAULT" serve "$DATA" 2>&1) || true
case "$OUT" in
  err*) : ;;
  *) fail "白名单不含父进程应拒绝（got: $OUT）";;
esac
pass "独立运行拒绝（父进程不在白名单）"

# ── 4. 错误握手 ─────────────────────────────────────────────────────
OUT=$(printf 'WRONG\n' | "$VAULT" serve "$DATA" 2>&1) || true
case "$OUT" in
  err*) : ;;
  *) fail "错误握手格式应拒绝（got: $OUT）";;
esac
OUT=$(printf 'handshake AAA BBB\n' | "$VAULT" serve "$DATA" 2>&1) || true
case "$OUT" in
  err*) : ;;
  *) fail "握手负载长度错误应拒绝（got: $OUT）";;
esac
pass "错误握手（格式/长度）被拒"

# ── 5. 磁盘无明文 ───────────────────────────────────────────────────
if grep -rq "$PASS" "$DATA" 2>/dev/null; then fail "磁盘出现明文"; fi
pass "磁盘无明文（vault/份额文件均不含明文串）"

# ── 6. 仅 vault 侧份额无法解密（缺 S → 握手即 err，fail-closed）────
rm -f "$DATA/insecure_master-share.bin"
python3 - "$VAULT" "$DATA" <<'PY' || fail "缺授权侧份额应 fail-closed"
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
env = dict(os.environ)
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
p.stdin.write(("handshake %s %s\n" % (
    base64.b64encode(os.urandom(32)).decode(),
    base64.b64encode(os.urandom(16)).decode())).encode())
p.stdin.flush()
resp = p.stdout.readline().decode().rstrip("\n")
assert resp.startswith("err SHARE_MISSING"), "缺授权侧份额应 SHARE_MISSING: %r" % resp
p.stdin.close(); p.wait(timeout=5)
assert p.returncode != 0, "拒绝路径应非零退出"
print("ok")
PY
pass "仅 vault 文件无法解密（2-of-2 生效，SHARE_MISSING）"

# 恢复现场：重建
run destroy "$DATA" >/dev/null || fail "destroy 失败"
run init "$DATA" >/dev/null || fail "重建 init 失败"

# ── 7. 篡改检测（GCM 认证失败 → 握手 err）──────────────────────────
# 翻转密文尾字节（tag 区）——salt 等元数据不参与认证，篡改无感；tag 必须被校验
python3 - "$DATA/credentials.vault" <<'PY' || fail "篡改脚本失败"
import sys
p = sys.argv[1]
b = bytearray(open(p, 'rb').read())
b[-1] ^= 0xFF  # 最后 1 字节落在 AES-GCM tag 内
open(p, 'wb').write(b)
PY
python3 - "$VAULT" "$DATA" <<'PY' || fail "篡改后应认证失败"
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
env = dict(os.environ)
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
p.stdin.write(("handshake %s %s\n" % (
    base64.b64encode(os.urandom(32)).decode(),
    base64.b64encode(os.urandom(16)).decode())).encode())
p.stdin.flush()
resp = p.stdout.readline().decode().rstrip("\n")
assert resp.startswith("err SHARE_MISMATCH"), "篡改后应 SHARE_MISMATCH: %r" % resp
p.stdin.close(); p.wait(timeout=5)
print("ok")
PY
pass "密文篡改被 GCM 认证拦截（SHARE_MISMATCH）"

# 恢复现场：重建（篡改文件不可复用，供后续崩溃联动测试握手成功）
run destroy "$DATA" >/dev/null || fail "destroy 失败"
run init "$DATA" >/dev/null || fail "重建 init 失败"

# ── 8. 崩溃联动前提：父进程可感知信号退出（§3.7）───────────────────
# 会话中 SIGKILL → 父进程 wait 观察到负 returncode（信号终止）→ Dart 侧据此
# 写 crash 标记并联动终止（vault.marker/abort 的写入方是 Dart VaultProcess）。
# 注：不用 SIGSEGV——NativeAOT 运行时接管 SIGSEGV 后进入挂起诊断态，不退出；
# 信号终止的可感知性以 SIGKILL 为准（VaultProcess 对任何信号/挂起均判非预期）。
python3 - "$VAULT" "$DATA" <<'PY' || fail "信号终止应被父进程感知"
import base64, os, signal, subprocess, sys
vault, data = sys.argv[1:3]
env = dict(os.environ)
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
p.stdin.write(("handshake %s %s\n" % (
    base64.b64encode(os.urandom(32)).decode(),
    base64.b64encode(os.urandom(16)).decode())).encode())
p.stdin.flush()
resp = p.stdout.readline().decode().rstrip("\n")
assert resp.startswith("ok handshake"), "握手应成功: %r" % resp
os.kill(p.pid, signal.SIGKILL)
p.wait(timeout=5)
assert p.returncode < 0, "SIGKILL 应致信号退出，got %r" % p.returncode
print("ok")
PY
pass "崩溃联动前提：会话信号终止可被父进程感知（信号退出码）"

# ── 9. 销毁 ─────────────────────────────────────────────────────────
run destroy "$DATA" | grep -q '^ok$' || fail "destroy 失败"
run status "$DATA" | grep -q '"initialized":false' || fail "destroy 后应未初始化"
[ ! -f "$DATA/credentials.vault" ] || fail "destroy 后 vault 文件应删除"
pass "destroy 全量销毁（份额+vault 文件）"

# ── 10. Argon2id 自检（RFC 9106 §5.3 向量）──────────────────────────
OUT=$(run selftest)
case "$OUT" in
  ok*) : ;;
  *) fail "Argon2id 自检失败: $OUT";;
esac
pass "Argon2id 自检（RFC 9106 向量）"

# ── 11. 口令模式全链路（init-password → 带口令握手 → set/get/quit）──
PW2="C0mpl3x-P@ss-网易"
B64PW=$(printf '%s' "$PW2" | base64 -w0)
OUT=$(printf '%s\n' "$PW2" | "$VAULT" init-password "$DATA2" 2>&1) || true
case "$OUT" in
  ok\ *) : ;;
  *) fail "init-password 失败: $OUT";;
esac
[ -f "$DATA2/credentials.vault" ] || fail "init-password 应生成 credentials.vault"
run status "$DATA2" | grep -q '"mode":"password"' || fail "口令模式 status 应为 mode=password"
pass "init-password（口令走 stdin，不落 argv）+ status mode=password"

python3 - "$VAULT" "$DATA2" "$B64PW" <<'PY' || fail "口令模式 serve 链路失败"
import base64, hashlib, hmac, os, subprocess, sys

vault, data, b64pw = sys.argv[1:4]
env = dict(os.environ)
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)

def cmd(line, payload=None):
    if payload is None:
        p.stdin.write((line + "\n").encode())
    else:
        p.stdin.write((line + "\n" + payload + "\n").encode())
    p.stdin.flush()
    return p.stdout.readline().decode().rstrip("\n")

# 口令模式握手：第 4 字段为 base64 口令（H=32B / C=16B，同 OS 模式）
h, c = os.urandom(32), os.urandom(16)
resp = cmd("handshake %s %s %s" % (
    base64.b64encode(h).decode(), base64.b64encode(c).decode(), b64pw))
parts = resp.split(" ")
assert parts[:2] == ["ok", "handshake"], "口令握手应答异常: %r" % resp
t = base64.b64decode(parts[2])
mac = base64.b64decode(parts[3])
assert len(t) == 16, "锚点应 16B"
assert mac == hmac.new(h, c, hashlib.sha256).digest(), "HMAC-SHA256 校验失败"
assert parts[4].startswith("ARCHOERA-VAULT-TEST"), "握手应上报 TEST 构建标记: %r" % resp

uid = "netease:cookie"
secret = base64.b64encode(b"password-mode-secret").decode()
assert cmd("set %s" % uid, secret) == "ok", "set 失败"
assert cmd("get %s" % uid).split(" ", 1)[1] == secret, "get 回读不一致"
assert cmd("quit") == "ok", "quit 失败"
p.wait(timeout=10)
assert p.returncode == 0, "quit 后应正常退出，got %r" % p.returncode
print("ok")
PY
pass "口令模式 serve 全链路（正确口令握手 + set/get/quit）"

# ── 12. 错误口令锁定退避 + 锁定期间拒绝 + 退避后恢复 ────────────────
python3 - "$VAULT" "$DATA2" "$B64PW" <<'PY' || fail "口令锁定链路失败"
import base64, os, subprocess, sys, time

vault, data, b64pw = sys.argv[1:4]
env = dict(os.environ)
WRONG = base64.b64encode(b"totally-wrong-password").decode()

def attempt(password):
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    h, c = os.urandom(32), os.urandom(16)
    p.stdin.write(("handshake %s %s %s\n" % (
        base64.b64encode(h).decode(), base64.b64encode(c).decode(), password)).encode())
    p.stdin.flush()
    resp = p.stdout.readline().decode().rstrip("\n")
    p.stdin.close()
    p.wait(timeout=10)
    return resp, p.returncode

# 错误口令 → 解锁失败（记录退避，首败 1s）
resp, rc = attempt(WRONG)
assert resp.startswith("err"), "错误口令应被拒: %r" % resp
assert rc == 1, "拒绝路径应非零退出，got %r" % rc
# 锁定期间：正确口令也直接拒绝（连 KDF 尝试都不做），fail-closed
resp, rc = attempt(b64pw)
assert resp.startswith("err") and "锁定" in resp, "锁定期间应拒绝: %r" % resp
assert rc == 1
# 退避过期（首败 1s，等 2.5s）→ 正确口令恢复，且 lockout 清零
time.sleep(2.5)
resp, rc = attempt(b64pw)
assert resp.startswith("ok handshake"), "退避过期后应可解锁: %r" % resp
assert rc == 0, "解锁会话应正常退出，got %r" % rc
print("ok")
PY
pass "错误口令锁定退避 + 锁定期间拒绝 + 退避后恢复"

# ── 13. 设备熵多封装（BitLocker 式）：本机免密 / 换机落恢复 / 篡改 fail-closed ──
PW3="Recovery-P@ss-迁移"
B64PW3=$(printf '%s' "$PW3" | base64 -w0)
OUT=$(ARCHOERA_VAULT_FINGERPRINT="fp-A" "$VAULT" init-device "$DATA3" --set-recovery-password \
  <<< "$PW3" 2>&1) || true
case "$OUT" in
  ok\ *) : ;;
  *) fail "init-device 失败: $OUT";;
esac
[ -f "$DATA3/credentials.vault" ] || fail "init-device 应生成 credentials.vault"
[ -f "$DATA3/device.seal" ] || fail "init-device 应生成 device.seal"
run status "$DATA3" | grep -q '"mode":"multiseal"' || fail "设备熵模式 status 应为 mode=multiseal"
pass "init-device（熵封装 + 可选恢复口令）+ status mode=multiseal"

python3 - "$VAULT" "$DATA3" "$B64PW3" <<'PY' || fail "设备熵多封装链路失败"
import base64, os, subprocess, sys

vault, data, b64pw = sys.argv[1:4]
env = dict(os.environ)

def session(fingerprint=None, password=None, cmds=()):
    e = dict(env)
    if fingerprint: e["ARCHOERA_VAULT_FINGERPRINT"] = fingerprint
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
    h, c = os.urandom(32), os.urandom(16)
    line = "handshake %s %s" % (
        base64.b64encode(h).decode(), base64.b64encode(c).decode())
    if password: line += " " + base64.b64encode(password.encode()).decode()
    p.stdin.write((line + "\n").encode())
    for cmd in cmds:
        p.stdin.write((cmd + "\n").encode())
    p.stdin.close()
    out = p.stdout.read().decode().splitlines()
    p.wait(timeout=15)
    return out

def b64(b): return base64.b64encode(b).decode()
SECRET = b"device-bound-secret"

# ① 本机免密（熵路径）：无口令握手 set/get 全链路
out = session(fingerprint="fp-A", cmds=[
    "set kugou", b64(SECRET), "get kugou", "quit"])
assert out[0].startswith("ok handshake"), "本机免密握手失败: %r" % out
assert "ok " + b64(SECRET) in out, "本机免密 get 回读不一致: %r" % out

# ② 换机（不同指纹）无口令 → NEED_RECOVERY（不计入锁定退避）
out = session(fingerprint="fp-B", cmds=["quit"])
assert out and out[0].startswith("err NEED_RECOVERY"), "换机应 NEED_RECOVERY: %r" % out

# ③ 换机 + 恢复口令 → 解锁成功，数据一致（恢复流成功清零 lockout）
out = session(fingerprint="fp-B", password="Recovery-P@ss-迁移", cmds=["get kugou", "quit"])
assert out[0].startswith("ok handshake"), "恢复口令解锁失败: %r" % out
assert "ok " + b64(SECRET) in out, "恢复后数据不一致: %r" % out

# ④ 篡改 device.seal 1 字节（本机指纹）→ NEED_RECOVERY（GCM fail-closed）
seal = os.path.join(data, "device.seal")
raw = bytearray(open(seal, "rb").read())
open(seal, "wb").write(bytes(raw[:-1]) + bytes([raw[-1] ^ 0x01]))
out = session(fingerprint="fp-A", cmds=["quit"])
assert out and out[0].startswith("err NEED_RECOVERY"), "篡改应 NEED_RECOVERY: %r" % out
open(seal, "wb").write(bytes(raw))  # 恢复原文件，供后续用例继续使用

# ⑤ 错误恢复口令 → 解锁失败（触发锁定退避，fail-closed）
out = session(fingerprint="fp-B", password="wrong-password", cmds=["quit"])
assert out and out[0].startswith("err"), "错误恢复口令应被拒: %r" % out
print("ok")
PY
pass "设备熵多封装：本机免密 / 换机 NEED_RECOVERY / 恢复口令解锁 / 篡改 fail-closed / 错误口令锁定"

# ── 14. 恢复口令管理 + 重新绑定（须已解锁）：改口令/清口令/rebind ──
# 复用 DATA3（第 13 项遗留：multiseal + device.seal(fp-A) + 恢复口令 Recovery-P@ss-迁移）
python3 - "$VAULT" "$DATA3" <<'PY' || fail "恢复口令管理/rebind 链路失败"
import base64, os, subprocess, sys, time

vault, data = sys.argv[1:3]
env = dict(os.environ)
time.sleep(2.5)  # 等第 13 项结尾错误口令触发的锁定退避过期

def session(fingerprint=None, password=None, cmds=()):
    e = dict(env)
    if fingerprint: e["ARCHOERA_VAULT_FINGERPRINT"] = fingerprint
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
    h, c = os.urandom(32), os.urandom(16)
    line = "handshake %s %s" % (
        base64.b64encode(h).decode(), base64.b64encode(c).decode())
    if password: line += " " + base64.b64encode(password.encode()).decode()
    p.stdin.write((line + "\n").encode())
    for cmd in cmds:
        p.stdin.write((cmd + "\n").encode())
    p.stdin.close()
    out = p.stdout.read().decode().splitlines()
    p.wait(timeout=15)
    return out

def b64(b): return base64.b64encode(b).decode()

# ① 本机免密解锁 → 修改恢复口令（旧口令 Recovery-P@ss-迁移 立即失效）
out = session(fingerprint="fp-A", cmds=[
    "set-recovery-password " + b64(b"New-Recovery-2"), "quit"])
assert out[0].startswith("ok handshake"), "本机解锁失败: %r" % out
assert out[1] == "ok", "修改恢复口令失败: %r" % out

# ② 换机 fp-B + 新口令 → 解锁成功（成功清零 lockout，为后续各步铺路）
out = session(fingerprint="fp-B", password="New-Recovery-2", cmds=["quit"])
assert out[0].startswith("ok handshake"), "新口令应有效: %r" % out

# ③ 换机 fp-B 新口令解锁 → rebind 重绑定当前设备
out = session(fingerprint="fp-B", password="New-Recovery-2", cmds=["rebind", "quit"])
assert out[1].startswith("ok "), "rebind 失败: %r" % out

# ④ rebind 后 fp-B 无口令免密成功；旧指纹 fp-A 无口令 → NEED_RECOVERY
out = session(fingerprint="fp-B", cmds=["quit"])
assert out[0].startswith("ok handshake"), "rebind 后新指纹应免密: %r" % out
out = session(fingerprint="fp-A", cmds=["quit"])
assert out and out[0].startswith("err NEED_RECOVERY"), "旧指纹应落恢复: %r" % out

# ⑤ 本机 fp-B 无口令 → 清除恢复口令
out = session(fingerprint="fp-B", cmds=["clear-recovery-password", "quit"])
assert out[0].startswith("ok handshake"), "清除口令前解锁失败: %r" % out
assert out[1] == "ok true", "清除恢复口令失败: %r" % out

# ⑥ 换机 fp-C 无口令 → fail-closed（无口令封装，不是 NEED_RECOVERY）
out = session(fingerprint="fp-C", cmds=["quit"])
assert out and out[0].startswith("err") and "NEED_RECOVERY" not in out[0], \
    "清除口令后换机应 fail-closed: %r" % out

# ⑦ 等 ⑥ 触发的锁定退避过期后：换机 fp-B + 旧口令 → 失败（旧口令已失效）
time.sleep(2.5)
out = session(fingerprint="fp-B", password="Recovery-P@ss-迁移", cmds=["quit"])
assert out and out[0].startswith("err"), "旧口令应已失效: %r" % out
print("ok")
PY
pass "恢复口令管理：修改（旧口令立即失效）/ 新口令恢复 / rebind 新指纹免密旧指纹落恢复 / 清除后换机 fail-closed"

# ── 15. 关闭设备绑定（clear-device-seal）：清除熵封装回落口令模式 ──
PW4="Close-Bind-P@ss"
DATA4="$(mktemp -d)"
DATA5="$(mktemp -d)"
trap 'rm -rf "$DATA" "$DATA2" "$DATA3" "$DATA4" "$DATA5"' EXIT
OUT=$(ARCHOERA_VAULT_FINGERPRINT="fp-D" "$VAULT" init-device "$DATA4" --set-recovery-password \
  <<< "$PW4" 2>&1) || true
case "$OUT" in
  ok\ *) : ;;
  *) fail "init-device(DATA4) 失败: $OUT";;
esac

python3 - "$VAULT" "$DATA4" <<'PY' || fail "关闭设备绑定链路失败"
import base64, os, subprocess, sys

vault, data = sys.argv[1:3]
env = dict(os.environ)
SECRET = b"close-bind-secret"

def session(fingerprint=None, password=None, cmds=()):
    e = dict(env)
    if fingerprint: e["ARCHOERA_VAULT_FINGERPRINT"] = fingerprint
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
    h, c = os.urandom(32), os.urandom(16)
    line = "handshake %s %s" % (
        base64.b64encode(h).decode(), base64.b64encode(c).decode())
    if password: line += " " + base64.b64encode(password.encode()).decode()
    p.stdin.write((line + "\n").encode())
    for cmd in cmds:
        p.stdin.write((cmd + "\n").encode())
    p.stdin.close()
    out = p.stdout.read().decode().splitlines()
    p.wait(timeout=15)
    return out

def b64(b): return base64.b64encode(b).decode()
B64PW = b64(b"Close-Bind-P@ss")

# ① 本机免密解锁 set 一条凭据（建立待验证数据）
out = session(fingerprint="fp-D", cmds=["set kugou", b64(SECRET), "quit"])
assert out[0].startswith("ok handshake"), "免密解锁失败: %r" % out

# ② 错误恢复口令 → clear-device-seal 被拒（授权校验：GCM 认证失败，不降级）
out = session(fingerprint="fp-D", cmds=["clear-device-seal " + b64(b"wrong-pw"), "quit"])
assert out[0].startswith("ok handshake"), "关闭前解锁失败: %r" % out
assert out[1].startswith("err"), "错误口令应被拒: %r" % out
assert os.path.exists(os.path.join(data, "device.seal")), "拒绝不应删除 device.seal"

# ③ 正确恢复口令 → clear-device-seal：关闭设备绑定（清除熵封装 + device.seal）
out = session(fingerprint="fp-D", cmds=["clear-device-seal " + B64PW, "quit"])
assert out[0].startswith("ok handshake"), "关闭前解锁失败: %r" % out
assert out[1] == "ok true", "clear-device-seal 失败: %r" % out
assert not os.path.exists(os.path.join(data, "device.seal")), "关闭后 device.seal 应删除"

# ④ 关闭后无口令握手 → 拒绝（已回落口令模式，v2 语义）
out = session(fingerprint="fp-D", cmds=["quit"])
assert out and out[0].startswith("err"), "关闭后无口令应被拒: %r" % out

# ⑤ 关闭后口令握手 → 解锁成功，数据一致（重加密以 K' 落盘，K' 由口令派生）
out = session(password="Close-Bind-P@ss", cmds=["get kugou", "quit"])
assert out[0].startswith("ok handshake"), "口令解锁失败: %r" % out
assert "ok " + b64(SECRET) in out, "关闭后数据不一致: %r" % out
print("ok")
PY
run status "$DATA4" | grep -q '"mode":"password"' || fail "关闭后 status 应为 mode=password"
pass "关闭设备绑定：回落口令模式（数据一致 / 无口令被拒 / status=password）"

# ── 15b. 无恢复口令的绑定 vault → clear-device-seal 以新口令免授权降级
#      （与「免密开启」对称：纯熵绑定无口令可验，关闭即新设 v2 口令）──
OUT=$(ARCHOERA_VAULT_FINGERPRINT="fp-E" "$VAULT" init-device "$DATA5" 2>&1) || true
case "$OUT" in
  ok\ *) : ;;
  *) fail "init-device(DATA5, 无口令) 失败: $OUT";;
esac
python3 - "$VAULT" "$DATA5" <<'PY' || fail "无恢复口令绑定 vault 关闭回落失败"
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
env = dict(os.environ)
env["ARCHOERA_VAULT_FINGERPRINT"] = "fp-E"

def session(fingerprint, cmds, password=None):
    e = dict(env)
    e["ARCHOERA_VAULT_FINGERPRINT"] = fingerprint
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
    h, c = os.urandom(32), os.urandom(16)
    handshake = "handshake %s %s\n" % (
        base64.b64encode(h).decode(), base64.b64encode(c).decode())
    if password is not None:
        handshake = handshake.rstrip("\n") + " " + base64.b64encode(password).decode() + "\n"
    p.stdin.write(handshake.encode())
    for cmd in cmds:
        p.stdin.write((cmd + "\n").encode())
    p.stdin.close()
    out = p.stdout.read().decode().splitlines()
    p.wait(timeout=15)
    return out

payload = base64.b64encode(b'{"t":"1"}').decode()
# ① 免密会话写入一条凭据（set uid 后值经 stdin 下一行传入）
out = session("fp-E", ["set kugou", payload, "quit"])
assert out[1] == "ok", "免密 set 失败: %r" % out
# ② 免密会话关闭绑定：以新口令直接降级（无恢复口令免授权）
newpw = b"new-password-42"
out = session("fp-E", ["clear-device-seal " + base64.b64encode(newpw).decode(), "quit"])
assert out[1] == "ok true", "clear-device-seal 失败: %r" % out
assert not os.path.exists(os.path.join(data, "device.seal")), "降级应删除 device.seal"
# ③ 回落 password 模式：免密会话被拒；新口令解锁回读数据一致
out = session("fp-E", ["get kugou", "quit"])
assert out[0].startswith("err"), "降级后免密会话应被拒: %r" % out
out = session("fp-E", ["get kugou", "quit"], password=newpw)
assert out[1] == "ok " + payload, "新口令解锁回读失败: %r" % out
print("ok")
PY
pass "无恢复口令的绑定 vault：clear-device-seal 以新口令免授权降级（对称于免密开启）"

# ── 16. v1/v2 → v3 迁移（upgrade-device）：key_vault 不变条目沿用 / 熵+口令双路径 ──
DATA6="$(mktemp -d)"
DATA7="$(mktemp -d)"
trap 'rm -rf "$DATA" "$DATA2" "$DATA3" "$DATA4" "$DATA5" "$DATA6" "$DATA7"' EXIT
python3 - "$VAULT" "$DATA6" "$DATA7" <<'PY' || fail "v1/v2 → v3 迁移链路失败"
import base64, os, subprocess, sys

vault, data6, data7 = sys.argv[1:4]
env = dict(os.environ)

def session(data, fingerprint=None, password=None, cmds=()):
    e = dict(env)
    if fingerprint: e["ARCHOERA_VAULT_FINGERPRINT"] = fingerprint
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
    h, c = os.urandom(32), os.urandom(16)
    line = "handshake %s %s" % (
        base64.b64encode(h).decode(), base64.b64encode(c).decode())
    if password: line += " " + base64.b64encode(password.encode()).decode()
    p.stdin.write((line + "\n").encode())
    for cmd in cmds:
        p.stdin.write((cmd + "\n").encode())
    p.stdin.close()
    out = p.stdout.read().decode().splitlines()
    p.wait(timeout=15)
    return out

def b64(b): return base64.b64encode(b).decode()
SECRET = b"upgraded-vault-secret"

# ── v1（OS 模式）→ v3 ──────────────────────────────────────────────
os.system("%s init %s >/dev/null" % (vault, data6))
assert os.path.exists(os.path.join(data6, "credentials.vault")), "v1 init 失败"

# ① OS 模式免密会话 set 一条数据（升级前基线）
out = session(data6, cmds=["set kugou", b64(SECRET), "quit"])
assert out[0].startswith("ok handshake"), "v1 免密会话失败: %r" % out

# ② upgrade-device（不设恢复口令）→ mode=multiseal + device.seal 生成
out = session(data6, fingerprint="fp-U1", cmds=["upgrade-device", "quit"])
assert out[0].startswith("ok handshake"), "升级前解锁失败: %r" % out
assert out[1].startswith("ok "), "upgrade-device 失败: %r" % out
assert os.path.exists(os.path.join(data6, "device.seal")), "升级后应生成 device.seal"

# ③ 升级后本机免密（熵路径）：既有数据一致（key_vault 不变，条目沿用）
out = session(data6, fingerprint="fp-U1", cmds=["get kugou", "quit"])
assert out[0].startswith("ok handshake"), "升级后免密解锁失败: %r" % out
assert "ok " + b64(SECRET) in out, "v1→v3 升级后数据不一致: %r" % out

# ── v2（口令模式）→ v3（带恢复口令）────────────────────────────────
os.system("printf 'Old-Pw-密码' | %s init-password %s >/dev/null" % (vault, data7))
assert os.path.exists(os.path.join(data7, "credentials.vault")), "v2 init 失败"

# ④ v2 口令会话 set 一条数据
out = session(data7, password="Old-Pw-密码", cmds=["set netease", b64(SECRET), "quit"])
assert out[0].startswith("ok handshake"), "v2 口令会话失败: %r" % out

# ⑤ upgrade-device --set-recovery-password（v2 解锁后补建熵+口令双封装）
RECOVERY = "Upgrade-Recovery-P@ss"
out = session(data7, fingerprint="fp-U2", password="Old-Pw-密码",
              cmds=["upgrade-device --set-recovery-password " + b64(RECOVERY.encode()), "quit"])
assert out[0].startswith("ok handshake"), "v2 升级前解锁失败: %r" % out
assert out[1].startswith("ok "), "v2 upgrade-device 失败: %r" % out

# ⑥ 升级后：本机免密数据一致
out = session(data7, fingerprint="fp-U2", cmds=["get netease", "quit"])
assert out[0].startswith("ok handshake"), "v2→v3 免密解锁失败: %r" % out
assert "ok " + b64(SECRET) in out, "v2→v3 升级后数据不一致: %r" % out

# ⑦ 换机（fp-U3）无口令 → NEED_RECOVERY（v2 的旧口令已不参与 v3 解锁）
out = session(data7, fingerprint="fp-U3", cmds=["quit"])
assert out and out[0].startswith("err NEED_RECOVERY"), "换机应 NEED_RECOVERY: %r" % out

# ⑧ 换机 + 新恢复口令 → 解锁成功，数据一致
out = session(data7, fingerprint="fp-U3", password=RECOVERY, cmds=["get netease", "quit"])
assert out[0].startswith("ok handshake"), "恢复口令解锁失败: %r" % out
assert "ok " + b64(SECRET) in out, "恢复口令路径数据不一致: %r" % out

# ⑨ 已 multiseal → upgrade-device 拒绝
out = session(data6, fingerprint="fp-U1", cmds=["upgrade-device", "quit"])
assert out[0].startswith("ok handshake"), "免密解锁失败: %r" % out
assert out[1].startswith("err"), "已 multiseal 应拒绝升级: %r" % out
print("ok")
PY
run status "$DATA6" | grep -q '"mode":"multiseal"' || fail "v1→v3 后 status 应为 multiseal"
run status "$DATA7" | grep -q '"mode":"multiseal"' || fail "v2→v3 后 status 应为 multiseal"
pass "v1/v2 → v3 迁移（upgrade-device：数据沿用 / 熵+恢复口令双路径 / 换机恢复 / 已绑定拒绝）"

# ── 17. v1 ↔ v2 份额迁移（switch-mode：OS ↔ 口令，K 不变条目沿用）──
DATA8="$(mktemp -d)"
trap 'rm -rf "$DATA" "$DATA2" "$DATA3" "$DATA4" "$DATA5" "$DATA6" "$DATA7" "$DATA8"' EXIT

python3 - "$VAULT" "$DATA8" <<'PY' || fail "v1↔v2 互切链路失败"
import base64, os, subprocess, sys

vault, data = sys.argv[1:3]
env = dict(os.environ)
SECRET = b"switch-mode-secret"
NEWPW = "V2-New-P@ss"

def session(password=None, cmds=()):
    e = dict(env)
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
    h, c = os.urandom(32), os.urandom(16)
    line = "handshake %s %s" % (
        base64.b64encode(h).decode(), base64.b64encode(c).decode())
    if password: line += " " + base64.b64encode(password.encode()).decode()
    p.stdin.write((line + "\n").encode())
    for cmd in cmds:
        p.stdin.write((cmd + "\n").encode())
    p.stdin.close()
    out = p.stdout.read().decode().splitlines()
    p.wait(timeout=15)
    return out

def b64(b): return base64.b64encode(b).decode()

# ① v1（OS 模式）初始化 + 免密会话 set 一条数据（切换前基线）
os.system("%s init %s >/dev/null" % (vault, data))
assert os.path.exists(os.path.join(data, "credentials.vault")), "v1 init 失败"
out = session(cmds=["set kugou", b64(SECRET), "quit"])
assert out[0].startswith("ok handshake"), "v1 免密会话失败: %r" % out

# ② v1 → v2：免密会话内 switch-mode password <新口令>；数据一致（K 不变）
out = session(cmds=["switch-mode password " + b64(NEWPW.encode()), "get kugou", "quit"])
assert out[0].startswith("ok handshake"), "切换前解锁失败: %r" % out
assert out[1] == "ok", "v1→v2 switch-mode 失败: %r" % out
assert "ok " + b64(SECRET) in out, "v1→v2 后数据不一致: %r" % out

# ③ 切到 v2 后：无口令握手被拒；带新口令握手成功且数据一致
out = session(cmds=["quit"])
assert out and out[0].startswith("err"), "v2 模式无口令应被拒: %r" % out
out = session(password=NEWPW, cmds=["get kugou", "quit"])
assert out[0].startswith("ok handshake"), "v2 口令解锁失败: %r" % out
assert "ok " + b64(SECRET) in out, "v2 路径数据不一致: %r" % out

# ④ v2 → v1：口令会话内 switch-mode os（无需口令，会话已解锁持 K）
out = session(password=NEWPW, cmds=["switch-mode os", "get kugou", "quit"])
assert out[0].startswith("ok handshake"), "v2 解锁失败: %r" % out
assert out[1] == "ok", "v2→v1 switch-mode 失败: %r" % out
assert "ok " + b64(SECRET) in out, "v2→v1 后数据不一致: %r" % out

# ⑤ 回到 v1：免密解锁成功，数据一致
out = session(cmds=["get kugou", "quit"])
assert out[0].startswith("ok handshake"), "回到 v1 免密解锁失败: %r" % out
assert "ok " + b64(SECRET) in out, "回到 v1 数据不一致: %r" % out
print("ok")
PY
run status "$DATA8" | grep -q '"mode":"os"' || fail "v2→v1 后 status 应为 os"
pass "v1 ↔ v2 互切（switch-mode：K 不变数据沿用 / 无口令被拒 / 口令切换 / 免密回归）"

# ── 18. 后端指纹不配对（不同构建形态混用数据目录 → SHARE_BACKEND_MISMATCH）──
DATA9="$(mktemp -d)"
trap 'rm -rf "$DATA" "$DATA2" "$DATA3" "$DATA4" "$DATA5" "$DATA6" "$DATA7" "$DATA8" "$DATA9"' EXIT

# ① backend=a 初始化：'O' 代号文件头记录后端指纹 a
OUT=$(ARCHOERA_VAULT_INSECURE_BACKEND=a "$VAULT" init "$DATA9" 2>&1) || true
case "$OUT" in
  ok\ *) : ;;
  *) fail "backend=a init 失败: $OUT";;
esac
python3 - "$DATA9/credentials.vault" <<'PY' || fail "'O' 代号文件头应记录后端指纹"
import sys
d = open(sys.argv[1], 'rb').read()
assert d[:4] == b'AVLT', "magic 不符"
assert d[4] == ord('O'), "应为 'O' 代号（OS 模式），got %d" % d[4]
blen = d[40]
assert d[41:41 + blen] == b'a', "backend 指纹不符: %r" % d[41:41 + blen]
print("ok")
PY

# ② backend=a 访问：指纹配对 → 握手解锁成功
python3 - "$VAULT" "$DATA9" <<'PY' || fail "配对后端应解锁成功"
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
env = dict(os.environ)
env["ARCHOERA_VAULT_INSECURE_BACKEND"] = "a"
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
p.stdin.write(("handshake %s %s\n" % (
    base64.b64encode(os.urandom(32)).decode(),
    base64.b64encode(os.urandom(16)).decode())).encode())
p.stdin.flush()
resp = p.stdout.readline().decode().rstrip("\n")
assert resp.startswith("ok handshake"), "配对后端应解锁: %r" % resp
p.stdin.close(); p.wait(timeout=5)
print("ok")
PY

# ③ backend=b 访问同一目录（模拟另一构建形态）→ SHARE_BACKEND_MISMATCH（明确错误码）
python3 - "$VAULT" "$DATA9" <<'PY' || fail "不配对后端应 SHARE_BACKEND_MISMATCH"
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
env = dict(os.environ)
env["ARCHOERA_VAULT_INSECURE_BACKEND"] = "b"
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
p.stdin.write(("handshake %s %s\n" % (
    base64.b64encode(os.urandom(32)).decode(),
    base64.b64encode(os.urandom(16)).decode())).encode())
p.stdin.flush()
resp = p.stdout.readline().decode().rstrip("\n")
assert resp.startswith("err SHARE_BACKEND_MISMATCH"), "应 SHARE_BACKEND_MISMATCH: %r" % resp
p.stdin.close(); p.wait(timeout=5)
print("ok")
PY

# ④ 回到 backend=a：仍可解锁（指纹校验只拦截不配对，不破坏配对会话）
python3 - "$VAULT" "$DATA9" <<'PY' || fail "配对后端应始终可解锁"
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
env = dict(os.environ)
env["ARCHOERA_VAULT_INSECURE_BACKEND"] = "a"
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
p.stdin.write(("handshake %s %s\n" % (
    base64.b64encode(os.urandom(32)).decode(),
    base64.b64encode(os.urandom(16)).decode())).encode())
p.stdin.flush()
resp = p.stdout.readline().decode().rstrip("\n")
assert resp.startswith("ok handshake"), "配对后端应解锁: %r" % resp
p.stdin.close(); p.wait(timeout=5)
print("ok")
PY
pass "后端指纹不配对（a 初始化/a 解锁/b → SHARE_BACKEND_MISMATCH/a 仍可解锁）"

# ── 19. LEGACY 方案（crypto 传统单因子）：K 整体存 OS 存储 / 免密 3 字段握手 ──
DATA10="$(mktemp -d)"
trap 'rm -rf "$DATA" "$DATA2" "$DATA3" "$DATA4" "$DATA5" "$DATA6" "$DATA7" "$DATA8" "$DATA9" "$DATA10"' EXIT

# ① init-crypto：'C' 代号文件头（key_vault 零占位 = 不含密钥材料）
OUT=$(ARCHOERA_VAULT_INSECURE_BACKEND=crypto-b "$VAULT" init-crypto "$DATA10" 2>&1) || true
case "$OUT" in
  ok\ *) [ -n "${OUT#ok }" ] || fail "init-crypto 应返回非空锚点";;
  *) fail "init-crypto 失败: $OUT";;
esac
[ -f "$DATA10/credentials.vault" ] || fail "init-crypto 应生成 credentials.vault"
python3 - "$DATA10/credentials.vault" <<'PY' || fail "'C' 代号文件头校验失败"
import sys
d = open(sys.argv[1], 'rb').read()
assert d[:4] == b'AVLT', "magic 不符"
assert d[4] == ord('C'), "应为 'C' 代号（LEGACY crypto），got %d" % d[4]
assert d[8:40] == bytes(32), "LEGACY 文件 key_vault 应为 32B 零占位（不含密钥材料）"
blen = d[40]
assert d[41:41 + blen] == b'crypto-b', "backend 指纹不符: %r" % d[41:41 + blen]
print("ok")
PY
run status "$DATA10" | grep -q '"mode":"crypto"' || fail "LEGACY 模式 status 应为 mode=crypto"
pass "init-crypto：'C' 代号文件头（key_vault 零占位 + 后端指纹）+ status mode=crypto"

# ② serve 全链路：免密 3 字段握手 → set/get/delete/quit
python3 - "$VAULT" "$DATA10" "$B64" "$UID1" <<'PY' || fail "crypto serve 链路失败"
import base64, hashlib, hmac, os, subprocess, sys
vault, data, b64, uid1 = sys.argv[1:5]
env = dict(os.environ)
env["ARCHOERA_VAULT_INSECURE_BACKEND"] = "crypto-b"
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)

def cmd(line, payload=None):
    if payload is None:
        p.stdin.write((line + "\n").encode())
    else:
        p.stdin.write((line + "\n" + payload + "\n").encode())
    p.stdin.flush()
    return p.stdout.readline().decode().rstrip("\n")

# crypto 免密握手：3 字段（H=32B / C=16B），应答含锚点 + HMAC + 构建标记
h, c = os.urandom(32), os.urandom(16)
resp = cmd("handshake %s %s" % (
    base64.b64encode(h).decode(), base64.b64encode(c).decode()))
parts = resp.split(" ")
assert parts[:2] == ["ok", "handshake"], "握手应答异常: %r" % resp
t = base64.b64decode(parts[2])
mac = base64.b64decode(parts[3])
assert len(t) == 16, "锚点应 16B"
assert mac == hmac.new(h, c, hashlib.sha256).digest(), "HMAC-SHA256 校验失败"
assert parts[4].startswith("ARCHOERA-VAULT-TEST"), "握手应上报 TEST 构建标记: %r" % resp

assert cmd("set %s" % uid1, b64) == "ok", "set 失败"
assert cmd("get %s" % uid1).split(" ", 1)[1] == b64, "get 回读不一致"
assert cmd("delete %s" % uid1) == "ok true", "delete 失败"
assert cmd("get %s" % uid1) == "ok null", "删除后应无条目"
assert cmd("quit") == "ok", "quit 失败"
p.wait(timeout=5)
assert p.returncode == 0, "quit 后应正常退出，got %r" % p.returncode
print("ok")
PY
pass "crypto serve 全链路（免密握手 HMAC + set/get/delete/quit）"

# ③ 缺 K（删 OS 存储条目）→ SHARE_MISSING，fail-closed（单因子同样 fail-closed）
rm -f "$DATA10/insecure_master-share.bin"
python3 - "$VAULT" "$DATA10" <<'PY' || fail "crypto 缺 K 应 fail-closed"
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
env = dict(os.environ)
env["ARCHOERA_VAULT_INSECURE_BACKEND"] = "crypto-b"
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
p.stdin.write(("handshake %s %s\n" % (
    base64.b64encode(os.urandom(32)).decode(),
    base64.b64encode(os.urandom(16)).decode())).encode())
p.stdin.flush()
resp = p.stdout.readline().decode().rstrip("\n")
assert resp.startswith("err SHARE_MISSING"), "crypto 缺 K 应 SHARE_MISSING: %r" % resp
p.stdin.close(); p.wait(timeout=5)
print("ok")
PY
pass "crypto 缺 K → SHARE_MISSING（fail-closed，无明文窗口）"

# ④ 后端不配对：LEGACY 文件头指纹照常校验（防构建形态混用数据目录）
#    重建 crypto 库后以不同后端访问 → SHARE_BACKEND_MISMATCH
run destroy "$DATA10" >/dev/null || fail "destroy 失败"
OUT=$(ARCHOERA_VAULT_INSECURE_BACKEND=x "$VAULT" init-crypto "$DATA10" 2>&1) || true
case "$OUT" in
  ok\ *) : ;;
  *) fail "重建 init-crypto(x) 失败: $OUT";;
esac
python3 - "$VAULT" "$DATA10" <<'PY' || fail "crypto 不配对后端应 SHARE_BACKEND_MISMATCH"
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
env = dict(os.environ)
env["ARCHOERA_VAULT_INSECURE_BACKEND"] = "y"
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
p.stdin.write(("handshake %s %s\n" % (
    base64.b64encode(os.urandom(32)).decode(),
    base64.b64encode(os.urandom(16)).decode())).encode())
p.stdin.flush()
resp = p.stdout.readline().decode().rstrip("\n")
assert resp.startswith("err SHARE_BACKEND_MISMATCH"), "应 SHARE_BACKEND_MISMATCH: %r" % resp
p.stdin.close(); p.wait(timeout=5)
print("ok")
PY

# ⑤ destroy：vault 文件 + K 删除，status 未初始化
run destroy "$DATA10" | grep -q '^ok$' || fail "destroy 失败"
run status "$DATA10" | grep -q '"initialized":false' || fail "destroy 后应未初始化"
pass "crypto 后端不配对（SHARE_BACKEND_MISMATCH）+ destroy 全量销毁"

echo "全部通过 ✔"
