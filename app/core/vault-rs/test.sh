#!/usr/bin/env bash
# vault（凭据保险库）冒烟测试：对 NativeAOT 产物做端到端验证。
#
# 支持的容器/模式：
#   - LEGACY 'C'（crypto 传统单因子）：init-crypto / init-file（file 后端）
#   - 'S'（slots）：init-m1（仅口令）/ init-m2a（口令+设备+恢复码）/ init-m2b（仅设备）
#
# 覆盖（serve 会话协议，credential-vault-plan §3.7/§3.8）：
#   1. init-crypto（'C'）全链路：serve set/get/delete/quit + 磁盘无明文 +
#      后端不配对（SHARE_BACKEND_MISMATCH）+ 篡改（SHARE_MISMATCH）+ destroy
#   2. init-file（--key-stdin）文件密钥模式 + 缺 secret.key → SHARE_MISSING + destroy
#   3. slots M1：init/status/serve/无明文/trailer 篡改/条目篡改/KDF 下界/.bak/destroy
#   4. slots M2a：init/status/device.key 0600/口令+设备解锁/错误口令/缺 device.key →
#      NEED_RECOVERY/恢复码/归一化/篡改/destroy
#   5. slots M2b：init/status/3 字段解锁/缺 device.key
#   6. 独立运行拒绝（父进程 exe 绑定）+ dev 布局放行
#   7. seccomp 自保护（过滤器生效 + AF_INET socket → SIGSYS；AF_UNIX 放行）
#   8. Argon2id 自检（RFC 9106 向量）
#   9. 用户可选 Argon2id 强度：init-m1/--kdf-* + set-kdf 重键（不丢数据）+
#      越界拒绝 + crypto 不支持 + m2a（含缺 device.key → NEED_RECOVERY）
#
# 说明：使用测试构建 build/archoera-vault-test（VAULT_TESTING 条件编译，与生产
# 唯一区别是构建标记为 TEST，存储行为完全一致）——headless CI 无 D-Bus Secret
# Service，故经 ARCHOERA_VAULT_BACKEND=file 选择**生产 FileStore**（文件密钥模式，
# 密钥落 secret.key）；真实平台存储（DPAPI/Keychain/libsecret）须在对应平台手动验证。
set -euo pipefail
cd "$(dirname "$0")"

VAULT="build/archoera-vault-test"
[ -x "$VAULT" ] || { echo "缺少测试产物，先运行 ./build-test.sh" >&2; exit 1; }

# 条件编译自检：测试产物须为 TEST 标记（非生产 PROD）——确保 build-test.sh 的
# VAULT_TESTING 生效；生产 build.sh 产物不含明文存储分支。
case "$("$VAULT" --version)" in
  ARCHOERA-VAULT-TEST-*) : ;;
  *) echo "测试产物标记异常（非 TEST），重新运行 ./build-test.sh" >&2; exit 1;;
esac

# headless 统一选择生产文件密钥后端（等价 init-file；无 D-Bus Secret Service）
export ARCHOERA_VAULT_BACKEND=file
DATA="$(mktemp -d)"       # crypto ('C')
DATA_FILE="$(mktemp -d)"  # init-file（file 后端）
DATA_M1="$(mktemp -d)"    # slots m1
DATA_M2A="$(mktemp -d)"   # slots m2a
DATA_M2B="$(mktemp -d)"   # slots m2b
DATA_PKG="$(mktemp -d)"   # 打包布局（父进程绑定）
DATA_KDF="$(mktemp -d)"   # slots m1：用户可选 KDF 强度 + set-kdf 重键
DATA_KDF2A="$(mktemp -d)" # slots m2a：KDF 强度 + 重键
DATA_KDFCR="$(mktemp -d)" # crypto：set-kdf 应不支持
trap 'rm -rf "$DATA" "$DATA_FILE" "$DATA_M1" "$DATA_M2A" "$DATA_M2B" "$DATA_PKG" \
  "$DATA_KDF" "$DATA_KDF2A" "$DATA_KDFCR"' EXIT

PASS="S3cr3t-P@ssword-酷狗"
B64=$(printf '%s' "$PASS" | base64 -w0)
UID1="kugou:session"
UID2="netease:cookie"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }

# vault 命令错误时退出码为 1，pipefail 下会污染管道状态；这里吞掉退出码，
# 仅以 stdout 内容为准（err/ok 前缀由调用方断言）。
run() { "$VAULT" "$@" 2>&1 || true; }

# 就地改写 crypto vault 文件头 backend 指纹（等长；长度不符即失败，防字段错位）。
rewrite_backend() {  # <vault> <old> <new>
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p = sys.argv[1]; old = sys.argv[2].encode(); new = sys.argv[3].encode()
assert len(old) == len(new), "后端名须等长（保持文件布局）"
b = bytearray(open(p, 'rb').read())
assert b[:4] == b'AVLT' and b[4] == ord('C'), "非 crypto 文件头"
blen = b[40]
assert bytes(b[41:41 + blen]) == old, "当前后端指纹 %r ≠ %r" % (bytes(b[41:41 + blen]), old)
b[41:41 + blen] = new
open(p, 'wb').write(bytes(b))
PY
}

# ════════════════════════════════════════════════════════════════════
# 1. LEGACY crypto（'C'）：init-crypto → serve 全链路 → 无明文 → 篡改 → destroy
# ════════════════════════════════════════════════════════════════════
OUT=$(run init-crypto "$DATA") || true
case "$OUT" in
  ok\ *) [ -n "${OUT#ok }" ] || fail "init-crypto 应返回非空锚点";;
  *) fail "init-crypto 失败: $OUT";;
esac
[ -f "$DATA/credentials.vault" ] || fail "init-crypto 应生成 credentials.vault"
python3 - "$DATA/credentials.vault" <<'PY' || fail "'C' 代号文件头校验失败"
import sys
d = open(sys.argv[1], 'rb').read()
assert d[:4] == b'AVLT', "magic 不符"
assert d[4] == ord('C'), "应为 'C' 代号（LEGACY crypto），got %d" % d[4]
assert d[8:40] == bytes(32), "LEGACY 文件 key_vault 应为 32B 零占位（不含密钥材料）"
blen = d[40]
assert d[41:41 + blen] == b'file', "backend 指纹应 file: %r" % d[41:41 + blen]
print("ok")
PY
run status "$DATA" | grep -q '"mode":"crypto"' || fail "crypto status 应为 mode=crypto"
pass "init-crypto：'C' 代号文件头（key_vault 零占位 + 后端指纹）+ status mode=crypto"

# serve 全链路：免密 3 字段握手 → set/get/delete/quit（按文件头自动 FileStore）
python3 - "$VAULT" "$DATA" "$B64" "$UID1" "$UID2" <<'PY' || fail "crypto serve 链路失败"
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

# crypto 免密握手：3 字段（H=32B / C=16B），应答含锚点 + HMAC + 构建标记
h, c = os.urandom(32), os.urandom(16)
resp = cmd("handshake %s %s" % (
    base64.b64encode(h).decode(), base64.b64encode(c).decode()))
parts = resp.split(" ")
assert parts[:2] == ["ok", "handshake"], "握手应答异常: %r" % resp
assert len(base64.b64decode(parts[2])) == 16, "锚点应 16B"
assert base64.b64decode(parts[3]) == hmac.new(h, c, hashlib.sha256).digest(), "HMAC 校验失败"
assert parts[4].startswith("ARCHOERA-VAULT-TEST"), "握手应上报 TEST 构建标记: %r" % resp

assert cmd("set %s" % uid1, b64) == "ok", "set 失败"
assert cmd("get %s" % uid1).split(" ", 1)[1] == b64, "get 回读不一致"
assert cmd("set %s" % uid2, base64.b64encode(b"another-secret").decode()) == "ok"
assert cmd("delete %s" % uid2) == "ok true", "delete 失败"
assert cmd("get %s" % uid2) == "ok null", "删除后应无条目"
assert cmd("quit") == "ok", "quit 失败"
p.wait(timeout=5)
assert p.returncode == 0, "quit 后应正常退出，got %r" % p.returncode
print("ok")
PY
pass "crypto serve 全链路（免密握手 HMAC + set/get/delete/quit）"

# 磁盘无明文（vault 文件与份额/密钥文件均不含明文串）
if grep -rq "$PASS" "$DATA" 2>/dev/null; then fail "磁盘出现明文"; fi
pass "crypto 磁盘无明文（vault/secret.key 均不含明文串）"

# 后端不配对：改写文件头 backend（file→otth）→ SHARE_BACKEND_MISMATCH
python3 - "$VAULT" "$DATA" <<'PY' || fail "配对后端应解锁成功"
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
assert resp.startswith("ok handshake"), "配对后端应解锁: %r" % resp
p.stdin.close(); p.wait(timeout=5)
print("ok")
PY
rewrite_backend "$DATA/credentials.vault" file otth
python3 - "$VAULT" "$DATA" <<'PY' || fail "不配对后端应 SHARE_BACKEND_MISMATCH"
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
env = dict(os.environ)
# 工厂按文件头分发：异名后端不再匹配 FileStore → 平台后端（Linux libsecret）。
# 仅需构造成功即可（指纹校验发生于触碰存储之前）；补一个非空 session bus 地址，
# 防「无 D-Bus」在构造期提前抛 SecretStoreUnavailable（免真实 keyring 依赖）。
env.setdefault("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent/archoera-vault-test")
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
rewrite_backend "$DATA/credentials.vault" otth file
pass "crypto 后端不配对（file→otth → SHARE_BACKEND_MISMATCH；还原后配对可解锁）"

# 篡改份额文件 secret.key（替换为随机 32B）→ 与 vault 不配对 → 回读锚点 GCM 失败 → SHARE_MISMATCH
python3 - "$DATA" <<'PY' || fail "篡改脚本失败"
import os, sys
open(os.path.join(sys.argv[1], "secret.key"), "wb").write(os.urandom(32))
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
pass "crypto 密文篡改被 GCM 认证拦截（SHARE_MISMATCH）"

run destroy "$DATA" | grep -q '^ok$' || fail "crypto destroy 失败"
run status "$DATA" | grep -q '"initialized":false' || fail "destroy 后应未初始化"
[ ! -f "$DATA/credentials.vault" ] || fail "destroy 后 vault 文件应删除"
[ ! -f "$DATA/secret.key" ] || fail "destroy 后 secret.key 应删除"
pass "crypto destroy 全量销毁（份额 + vault 文件）"

# ════════════════════════════════════════════════════════════════════
# 2. 文件密钥模式（init-file --key-stdin）：file 后端 + 缺 secret.key → SHARE_MISSING
# ════════════════════════════════════════════════════════════════════
KEYHEX=$(python3 -c "import secrets;print(secrets.token_hex(32))")
OUT=$(printf '%s\n' "$KEYHEX" | "$VAULT" init-file "$DATA_FILE" --key-stdin 2>&1) || true
case "$OUT" in ok\ *) : ;; *) fail "stdin 密钥 init-file 失败: $OUT";; esac
[ -f "$DATA_FILE/credentials.vault" ] || fail "init-file 应生成 credentials.vault"
[ -f "$DATA_FILE/secret.key" ] || fail "init-file 应生成 secret.key"
[ "$(stat -c %a "$DATA_FILE/secret.key")" = "600" ] || fail "secret.key 权限应 0600"

# stdin 注入的 K 位于 ShareBundle.share 字段 [6:38)；serve 用该 K 解锁并往返
python3 - "$VAULT" "$DATA_FILE" "$KEYHEX" "$B64" "$UID1" <<'PY' || fail "stdin 注入的密钥应解锁"
import base64, hashlib, hmac, os, subprocess, sys
vault, data, keyhex, b64, uid1 = sys.argv[1:6]
raw = open(os.path.join(data, "secret.key"), "rb").read()
assert raw[:4] == b"ASTB", "secret.key 应为 ShareBundle: %r" % raw[:4]
assert raw[6:38].hex() == keyhex, "ShareBundle 内嵌份额应为 stdin 注入的 K"
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def cmd(line, payload=None):
    if payload is None:
        p.stdin.write((line + "\n").encode())
    else:
        p.stdin.write((line + "\n" + payload + "\n").encode())
    p.stdin.flush()
    return p.stdout.readline().decode().rstrip("\n")

h, c = os.urandom(32), os.urandom(16)
resp = cmd("handshake %s %s" % (
    base64.b64encode(h).decode(), base64.b64encode(c).decode()))
parts = resp.split(" ")
assert parts[:2] == ["ok", "handshake"], "file 模式握手应成功: %r" % resp
assert base64.b64decode(parts[3]) == hmac.new(h, c, hashlib.sha256).digest(), "HMAC 校验失败"
assert cmd("set %s" % uid1, b64) == "ok", "set 失败"
assert cmd("get %s" % uid1).split(" ", 1)[1] == b64, "get 回读不一致"
assert cmd("quit") == "ok", "quit 失败"
p.wait(timeout=5)
assert p.returncode == 0, "quit 后应正常退出，got %r" % p.returncode
print("ok")
PY
pass "init-file（--key-stdin → ShareBundle 内嵌注入 K）+ file 后端 serve 全链路"

# 缺 secret.key → SHARE_MISSING（fail-closed，无明文窗口）
mv "$DATA_FILE/secret.key" "$DATA_FILE/secret.key.bak"
python3 - "$VAULT" "$DATA_FILE" <<'PY' || fail "file 缺密钥应 SHARE_MISSING"
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
p.stdin.write(("handshake %s %s\n" % (
    base64.b64encode(os.urandom(32)).decode(),
    base64.b64encode(os.urandom(16)).decode())).encode())
p.stdin.flush()
resp = p.stdout.readline().decode().rstrip("\n")
assert resp.startswith("err SHARE_MISSING"), "缺 secret.key 应 SHARE_MISSING: %r" % resp
p.stdin.close(); p.wait(timeout=5)
print("ok")
PY
mv "$DATA_FILE/secret.key.bak" "$DATA_FILE/secret.key"
pass "file 缺 secret.key → SHARE_MISSING（fail-closed）"

run destroy "$DATA_FILE" | grep -q '^ok$' || fail "file destroy 失败"
[ ! -f "$DATA_FILE/credentials.vault" ] || fail "destroy 应删除 credentials.vault"
[ ! -f "$DATA_FILE/secret.key" ] || fail "destroy 应删除 secret.key"
pass "file destroy 全量销毁（secret.key + vault 文件）"

# ════════════════════════════════════════════════════════════════════
# 3. 新容器 'S'（slots，M1 仅口令）
# ════════════════════════════════════════════════════════════════════
M1PW="M1-P@ss-槽位"
OUT=$(printf '%s\n' "$M1PW" | "$VAULT" init-m1 "$DATA_M1" 2>&1) || true
case "$OUT" in ok\ *) : ;; *) fail "init-m1 失败: $OUT";; esac

python3 - "$DATA_M1" <<'PY' || fail "init-m1 文件格式异常"
import os, struct, sys
d = sys.argv[1]
b = open(os.path.join(d, "credentials.vault"), "rb").read()
assert b[:4] == b"AVLT", "magic 异常: %r" % b[:4]
assert b[4] == ord("S"), "version 应为 'S': %r" % b[4]
assert len(b) > 32 + 3 * 4, "文件过短: %d" % len(b)
assert b[29] == 1, "algEnt 应为 1(AES-256-GCM): %r" % b[29]
assert b[30] == 1, "F1 应为单槽: %r" % b[30]
assert b[31] == 1, "槽位 kind 应为 1(口令): %r" % b[31]
m, t, p = struct.unpack_from("<III", b, 32)
assert m >= 8192 and t >= 1 and p >= 1, "KDF 参数应满足下界: m=%d t=%d p=%d" % (m, t, p)
print("ok")
PY
run status "$DATA_M1" | grep -q '"mode":"m1"' || fail "slots status 应为 mode=m1"
pass "init-m1（口令走 stdin）+ status mode=m1（magic AVLT / version 'S'）"

# 原子写：init-m1 内部 GetOrCreateAuthAnchor 触发一次 re-save → 保留上一版 .bak
[ -f "$DATA_M1/credentials.vault.bak" ] || fail "re-save 后应保留上一版 .bak"
cmp -s "$DATA_M1/credentials.vault" "$DATA_M1/credentials.vault.bak" && fail ".bak 不应与当前版本相同"
pass "原子写保留 .bak（重保存后可恢复上一版）"

# 磁盘无明文（slots 自包含：头部 + 条目 + trailer 均不含口令/明文）
if grep -rq "$M1PW" "$DATA_M1" 2>/dev/null; then fail "M1 磁盘出现口令明文"; fi
if grep -rq "m1-secret" "$DATA_M1" 2>/dev/null; then fail "M1 磁盘出现凭据明文"; fi
pass "M1 磁盘无明文（口令/凭据均不落盘）"

cp "$DATA_M1/credentials.vault" "$DATA_M1/pristine.vault"

python3 - "$VAULT" "$DATA_M1" "$M1PW" <<'PY' || fail "slots serve 链路失败"
import base64, os, struct, subprocess, sys
vault, data, pw = sys.argv[1:4]
path = os.path.join(data, "credentials.vault")
pristine = open(path, "rb").read()

def clear_lockout():
    # slots 无份额（NullSecretStore）→ 退避回退明文 vault.lockout（同口令模式）
    lk = os.path.join(data, "vault.lockout")
    if os.path.exists(lk):
        os.remove(lk)

def handshake(password):
    clear_lockout()
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ))
    line = "handshake %s %s %s\n" % (
        base64.b64encode(os.urandom(32)).decode(),
        base64.b64encode(os.urandom(16)).decode(),
        base64.b64encode(password.encode()).decode())
    try:
        p.stdin.write(line.encode()); p.stdin.flush()
    except (BrokenPipeError, OSError):
        pass
    resp = p.stdout.readline().decode().rstrip("\n")
    return p, resp

def cmd(p, line, payload=None):
    if payload is None:
        p.stdin.write((line + "\n").encode())
    else:
        p.stdin.write((line + "\n" + payload + "\n").encode())
    p.stdin.flush()
    return p.stdout.readline().decode().rstrip("\n")

def close(p):
    try: p.stdin.close()
    except OSError: pass
    p.wait(timeout=10)

# ① 正确口令 → set/get/delete 往返；错误口令 → err（无明文）
p, resp = handshake(pw)
assert resp.startswith("ok handshake"), "正确口令应握手: %r" % resp
sec = base64.b64encode(b"m1-secret").decode()
assert cmd(p, "set kugou:session", sec) == "ok", "set 失败"
assert cmd(p, "get kugou:session") == "ok " + sec, "get 回读不一致"
assert cmd(p, "delete kugou:session") == "ok true", "delete 失败（需重算尾部 HMAC）"
assert cmd(p, "get kugou:session") == "ok null", "删除后应无条目"
assert cmd(p, "quit") == "ok", "quit 失败"
p.wait(timeout=10)
assert p.returncode == 0, "quit 后应正常退出: %r" % p.returncode

p, resp = handshake("definitely-wrong-pw")
assert resp.startswith("err"), "错误口令应被拒: %r" % resp
assert "m1-secret" not in resp, "错误口令应答不应含明文"
close(p)

# ② 篡改 trailer 1 字节 → 解出 K 后 HMAC 校验失败（verify-before-decrypt）
b = bytearray(pristine); b[-1] ^= 0x01; open(path, "wb").write(bytes(b))
p, resp = handshake(pw)
assert resp.startswith("err"), "篡改 trailer 应被拒: %r" % resp
assert "m1-secret" not in resp, "篡改 trailer 应答不应含明文"
close(p)

# ③ 篡改条目区 1 字节（尾部 HMAC 覆盖 header‖entries）→ 拒绝
b = bytearray(pristine); b[-40] ^= 0x01; open(path, "wb").write(bytes(b))
p, resp = handshake(pw)
assert resp.startswith("err"), "篡改条目应被拒: %r" % resp
close(p)

# ④ KDF 下界：m=1024（offset 32，slot.kdfM）→ 加载即拒绝
b = bytearray(pristine); struct.pack_into("<I", b, 32, 1024); open(path, "wb").write(bytes(b))
p, resp = handshake(pw)
assert resp.startswith("err"), "KDF 下界应被拒: %r" % resp
close(p)

open(path, "wb").write(pristine)  # 复原
print("ok")
PY
pass "slots serve：正确口令 set/get/delete；错误口令/篡改 trailer/篡改条目/KDF 下界 全部拒绝"

# destroy 须一并删除 vault 文件与其 .bak 备份（重置不得残留可解副本）
run destroy "$DATA_M1" >/dev/null || fail "slots destroy 失败"
[ ! -f "$DATA_M1/credentials.vault" ] || fail "destroy 后 vault 文件应删除"
[ ! -f "$DATA_M1/credentials.vault.bak" ] || fail "destroy 后 .bak 备份应一并删除"
pass "slots destroy 全量销毁（vault 文件 + .bak 备份）"

# ════════════════════════════════════════════════════════════════════
# 4. 'S' slots F2：m2a（口令+设备）双因子 + 恢复码
# ════════════════════════════════════════════════════════════════════
M2APW="m2a-P@ss-设备"
# ① init-m2a：口令走 stdin，返回 `ok <b64锚点> <恢复码>`；device.key 落盘 0600
M2AOUT=$(printf '%s\n' "$M2APW" | "$VAULT" init-m2a "$DATA_M2A" 2>&1) || true
case "$M2AOUT" in ok\ *) : ;; *) fail "init-m2a 失败: $M2AOUT";; esac
M2ACODE=$(printf '%s\n' "$M2AOUT" | awk '{print $3}')
[ -n "$M2ACODE" ] || fail "init-m2a 应输出恢复码: $M2AOUT"
# 恢复码为 Crockford Base32（32B → 52 字符 → 13 组，`-` 分隔）
printf '%s' "$M2ACODE" | grep -Eq '^([0-9A-HJKMNP-TV-Z]{4}-){12}[0-9A-HJKMNP-TV-Z]{4}$' \
  || fail "恢复码分组/字符异常: $M2ACODE"
[ -f "$DATA_M2A/device.key" ] || fail "init-m2a 应生成 device.key"
[ "$(stat -c '%a' "$DATA_M2A/device.key")" = "600" ] || fail "device.key 权限应为 0600"
run status "$DATA_M2A" | grep -q '"mode":"m2a"' || fail "m2a status 应为 mode=m2a"

# 文件布局：slotCount=2，槽 1 kind=4（口令+设备），槽 2 kind=3（恢复）
python3 - "$DATA_M2A" <<'PY' || fail "m2a 文件格式异常"
import os, struct, sys
d = sys.argv[1]
b = open(os.path.join(d, "credentials.vault"), "rb").read()
assert b[:4] == b"AVLT" and b[4] == ord("S"), "magic/version 异常"
assert b[29] == 1, "algEnt 应为 1: %r" % b[29]
assert b[30] == 2, "m2a 应为 2 个槽位: %r" % b[30]
assert b[31] == 4, "槽 1 应为 PasswordDevice(4): %r" % b[31]
m, t, p = struct.unpack_from("<III", b, 32)
assert m >= 8192 and t >= 1 and p >= 1, "口令+设备槽 KDF 应满足下界"
# 槽 1 = kind(1)+m/t/p(12)+salt(16)+nonce(12)+len(2)+wrapped(48) → 槽 2 起点 122
assert b[122] == 3, "槽 2 应为 Recovery(3): %r" % b[122]
rm, rt, rp = struct.unpack_from("<III", b, 123)
assert (rm, rt, rp) == (0, 0, 0), "恢复槽 KDF 参数应为占位 0: %r" % ((rm, rt, rp),)
print("ok")
PY
pass "init-m2a（口令 + device.key 0600 + 恢复码）→ status mode=m2a；槽 4/3 布局正确"

# ②-⑤ m2a serve：口令/设备路径、错误口令、缺 device.key、恢复码路径、归一化、篡改
cp "$DATA_M2A/credentials.vault" "$DATA_M2A/pristine.vault"
python3 - "$VAULT" "$DATA_M2A" "$M2APW" "$M2ACODE" <<'PY' || fail "m2a serve 链路失败"
import base64, os, subprocess, sys
vault, data, pw, code = sys.argv[1:5]
path = os.path.join(data, "credentials.vault")
devkey = os.path.join(data, "device.key")
pristine = open(path, "rb").read()
pristine_dev = open(devkey, "rb").read()

def clear_lockout():
    lk = os.path.join(data, "vault.lockout")
    if os.path.exists(lk): os.remove(lk)

def handshake(secret=None, label=None, drop_device=False):
    clear_lockout()
    if drop_device and os.path.exists(devkey):
        os.remove(devkey)
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ))
    fields = [base64.b64encode(os.urandom(32)).decode(),
              base64.b64encode(os.urandom(16)).decode()]
    if secret is not None: fields.append(base64.b64encode(secret.encode()).decode())
    if label is not None: fields.append(base64.b64encode(label.encode()).decode())
    try:
        p.stdin.write(("handshake " + " ".join(fields) + "\n").encode()); p.stdin.flush()
    except (BrokenPipeError, OSError):
        pass
    resp = p.stdout.readline().decode().rstrip("\n")
    if drop_device:
        open(devkey, "wb").write(pristine_dev)   # 复原 device.key
    return p, resp

def cmd(p, line, payload=None):
    if payload is None: p.stdin.write((line + "\n").encode())
    else: p.stdin.write((line + "\n" + payload + "\n").encode())
    p.stdin.flush()
    return p.stdout.readline().decode().rstrip("\n")

def close(p):
    try: p.stdin.close()
    except OSError: pass
    p.wait(timeout=10)

# ② 正确口令 + device.key → set/get/delete 往返
p, resp = handshake(secret=pw)
assert resp.startswith("ok handshake"), "m2a 正确口令应握手: %r" % resp
sec = base64.b64encode(b"m2a-secret").decode()
assert cmd(p, "set kugou:session", sec) == "ok", "set 失败"
assert cmd(p, "get kugou:session") == "ok " + sec, "get 回读不一致"
assert cmd(p, "delete kugou:session") == "ok true", "delete 失败"
assert cmd(p, "quit") == "ok"; p.wait(timeout=10)
assert p.returncode == 0, "quit 后应正常退出"
open(path, "wb").write(pristine)  # 复原（后续用 pristine 做篡改基线）

# ③ 错误口令 → 拒绝（SHARE_MISMATCH，记退避）
p, resp = handshake(secret="definitely-wrong-pw")
assert resp.startswith("err") and "SHARE_MISMATCH" in resp, "m2a 错误口令应被拒: %r" % resp
assert "m2a-secret" not in resp, "错误口令应答不应含明文"
close(p)

# ④ device.key 缺失 → 口令路径拒绝，且为 NEED_RECOVERY（非 SHARE_MISMATCH）
p, resp = handshake(secret=pw, drop_device=True)
assert resp.startswith("err") and "NEED_RECOVERY" in resp, \
    "缺 device.key 应为 NEED_RECOVERY: %r" % resp
close(p)

# ⑤ 恢复码路径（不依赖 device.key）：正确 → set/get；错误 → 拒绝
p, resp = handshake(secret=code, label="rec", drop_device=True)
assert resp.startswith("ok handshake"), "m2a 恢复码应握手: %r" % resp
rsec = base64.b64encode(b"m2a-recovery").decode()
assert cmd(p, "set netease:cookie", rsec) == "ok", "恢复路径 set 失败"
assert cmd(p, "get netease:cookie") == "ok " + rsec, "恢复路径 get 不一致"
assert cmd(p, "quit") == "ok"; p.wait(timeout=10)
open(path, "wb").write(pristine)

# ⑤b 恢复码输入归一化（小写 + 空格代替 `-`）仍可解锁
p, resp = handshake(secret=code.lower().replace("-", " "), label="rec", drop_device=True)
assert resp.startswith("ok handshake"), "归一化恢复码应握手: %r" % resp
close(p)

# ⑤c 错误恢复码 → 拒绝
p, resp = handshake(secret="-".join(["0000"] * 13), label="rec")
assert resp.startswith("err"), "错误恢复码应被拒: %r" % resp
close(p)

# ⑤d 5 字段但标签未知 → 拒绝
p, resp = handshake(secret=code, label="bogus")
assert resp.startswith("err"), "未知标签应被拒: %r" % resp
close(p)

# 六 篡改 trailer 1 字节 → 解出 K 后 HMAC 校验失败（verify-before-decrypt）
b = bytearray(pristine); b[-1] ^= 0x01; open(path, "wb").write(bytes(b))
p, resp = handshake(secret=pw)
assert resp.startswith("err"), "m2a 篡改 trailer 应被拒: %r" % resp
assert "m2a-secret" not in resp, "篡改应答不应含明文"
close(p)

open(path, "wb").write(pristine)  # 复原
print("ok")
PY
pass "m2a serve：口令+设备 set/get；错误口令 / 缺 device.key(NEED_RECOVERY) / 恢复码 / 归一化 / 篡改 trailer 行为正确"

# destroy 一并删除 device.key
run destroy "$DATA_M2A" >/dev/null || fail "m2a destroy 失败"
[ ! -f "$DATA_M2A/credentials.vault" ] || fail "destroy 后 vault 文件应删除"
[ ! -f "$DATA_M2A/credentials.vault.bak" ] || fail "destroy 后 .bak 应一并删除"
[ ! -f "$DATA_M2A/device.key" ] || fail "destroy 后 device.key 应一并删除"
pass "m2a destroy 全量销毁（vault + .bak + device.key）"

# ════════════════════════════════════════════════════════════════════
# 5. 'S' slots F2：m2b（仅设备槽）
# ════════════════════════════════════════════════════════════════════
M2BOUT=$("$VAULT" init-m2b "$DATA_M2B" 2>&1) || true
case "$M2BOUT" in ok\ *) : ;; *) fail "init-m2b 失败: $M2BOUT";; esac
[ -f "$DATA_M2B/device.key" ] || fail "init-m2b 应生成 device.key"
[ "$(stat -c '%a' "$DATA_M2B/device.key")" = "600" ] || fail "m2b device.key 权限应为 0600"
run status "$DATA_M2B" | grep -q '"mode":"m2b"' || fail "m2b status 应为 mode=m2b"
python3 - "$DATA_M2B" <<'PY' || fail "m2b 文件格式异常"
import os, struct, sys
d = sys.argv[1]
b = open(os.path.join(d, "credentials.vault"), "rb").read()
assert b[:4] == b"AVLT" and b[4] == ord("S"), "magic/version 异常"
assert b[30] == 1, "m2b 应为 1 个槽位: %r" % b[30]
assert b[31] == 2, "槽应为 Device(2): %r" % b[31]
assert struct.unpack_from("<III", b, 32) == (0, 0, 0), "设备槽 KDF 参数应为占位 0"
print("ok")
PY
python3 - "$VAULT" "$DATA_M2B" <<'PY' || fail "m2b serve 链路失败"
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
devkey = os.path.join(data, "device.key")
pristine_dev = open(devkey, "rb").read()

def clear_lockout():
    lk = os.path.join(data, "vault.lockout")
    if os.path.exists(lk): os.remove(lk)

def handshake(drop_device=False):
    clear_lockout()
    if drop_device and os.path.exists(devkey): os.remove(devkey)
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ))
    line = "handshake %s %s\n" % (base64.b64encode(os.urandom(32)).decode(),
                                  base64.b64encode(os.urandom(16)).decode())
    try:
        p.stdin.write(line.encode()); p.stdin.flush()
    except (BrokenPipeError, OSError):
        pass
    resp = p.stdout.readline().decode().rstrip("\n")
    if drop_device: open(devkey, "wb").write(pristine_dev)
    return p, resp

def cmd(p, line, payload=None):
    if payload is None: p.stdin.write((line + "\n").encode())
    else: p.stdin.write((line + "\n" + payload + "\n").encode())
    p.stdin.flush(); return p.stdout.readline().decode().rstrip("\n")

# 3 字段 + device.key → set/get 往返
p, resp = handshake()
assert resp.startswith("ok handshake"), "m2b 3 字段应握手: %r" % resp
sec = base64.b64encode(b"m2b-secret").decode()
assert cmd(p, "set netease:cookie", sec) == "ok", "m2b set 失败"
assert cmd(p, "get netease:cookie") == "ok " + sec, "m2b get 回读不一致"
assert cmd(p, "quit") == "ok"; p.wait(timeout=10)
assert p.returncode == 0, "m2b quit 后应正常退出"

# 缺 device.key → 拒绝（distinct err）
p, resp = handshake(drop_device=True)
assert resp.startswith("err"), "m2b 缺 device.key 应被拒: %r" % resp
assert "NEED_RECOVERY" in resp or "device.key" in resp, "应给出设备密钥缺失提示: %r" % resp
try: p.stdin.close()
except OSError: pass
p.wait(timeout=10)
print("ok")
PY
pass "init-m2b（仅设备槽，0600）→ status mode=m2b；3 字段 set/get；缺 device.key 拒绝"

# ════════════════════════════════════════════════════════════════════
# 6. 独立运行拒绝（父进程 exe 绑定）+ dev 布局放行
# ════════════════════════════════════════════════════════════════════
# 打包布局：<dir>/native/<vault> + <dir>/archoera_music（预期主程序占位）。
# vault 由自身位置推导「预期主程序」路径，并经 OS 读取父进程可执行文件路径比对——
# 父进程非预期主程序（脚本/独立调用）即拒绝。dev 布局（build/）不作路径绑定，
# 故上文各 serve 用例（build/ 下运行）不受影响（dev 布局放行）。
mkdir -p "$DATA_PKG/native"
cp "$VAULT" "$DATA_PKG/native/archoera-vault-test"
cp "$VAULT" "$DATA_PKG/archoera_music"   # 预期主程序占位（仅路径比对，不执行）
PKGVAULT="$DATA_PKG/native/archoera-vault-test"

# 从 python3 启动（父进程 exe=python3 ≠ $DATA_PKG/archoera_music）→ 拒绝
OUT=$(python3 - "$PKGVAULT" "$DATA_M2B" <<'PY'
import subprocess, sys
vault, data = sys.argv[1:3]
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
p.stdin.write(b"handshake AAAA BBBB\n"); p.stdin.flush()
print(p.stdout.readline().decode().rstrip("\n"))
p.stdin.close(); p.wait(timeout=5)
PY
) || true
case "$OUT" in
  err*主程序*) : ;;
  *) fail "打包布局下父进程非预期主程序应拒绝（got: $OUT）";;
esac
pass "独立运行拒绝（打包布局：父进程 exe 非预期主程序）"

# dev 布局放行：build/ 下 serve 握手成功（上文各 serve 用例已证；此处显式再验一次）
python3 - "$VAULT" "$DATA_M2B" <<'PY' || fail "dev 布局应放行"
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
p.stdin.write(("handshake %s %s\n" % (
    base64.b64encode(os.urandom(32)).decode(),
    base64.b64encode(os.urandom(16)).decode())).encode())
p.stdin.flush()
resp = p.stdout.readline().decode().rstrip("\n")
assert resp.startswith("ok handshake"), "dev 布局应放行: %r" % resp
p.stdin.close(); p.wait(timeout=5)
print("ok")
PY
pass "dev 布局放行（build/ 下 serve 握手成功）"

# ════════════════════════════════════════════════════════════════════
# 6b. 加载器注入拒绝：LD_PRELOAD / LD_AUDIT 非空 → serve 在武装前拒绝
# ════════════════════════════════════════════════════════════════════
# Vector A：Linux 上 `LD_PRELOAD=<evil.so>` 可在动态装载期 hook vault 的 read，
# 从 stdin 握手窃取明文口令。PlatformGuard.VerifyAndArm 在武装前检查注入变量并
# 直接拒绝（Dart 侧 spawn 另有环境净化，双保险）。此处用**不存在**的 .so 路径，
# 仅验证拒绝分支（不会真正加载）；上方无注入的各 serve 用例须保持绿。
LD_PRELOAD_OUT=$(LD_PRELOAD=/nonexistent/archoera-inject-test.so \
  "$VAULT" serve "$DATA_M2B" <<<'handshake AAAA BBBB' 2>/dev/null) || true
case "$LD_PRELOAD_OUT" in
  err*拒绝运行*) : ;;
  *) fail "LD_PRELOAD 非空应被 vault 拒绝（got: $LD_PRELOAD_OUT）";;
esac
LD_AUDIT_OUT=$(LD_AUDIT=/nonexistent/archoera-inject-test.so \
  "$VAULT" serve "$DATA_M2B" <<<'handshake AAAA BBBB' 2>/dev/null) || true
case "$LD_AUDIT_OUT" in
  err*拒绝运行*) : ;;
  *) fail "LD_AUDIT 非空应被 vault 拒绝（got: $LD_AUDIT_OUT）";;
esac
pass "加载器注入拒绝（LD_PRELOAD / LD_AUDIT 非空 → serve err 拒绝运行）"

# ════════════════════════════════════════════════════════════════════
# 7. seccomp 自保护：过滤器已装载 + 违例系统调用被内核 SIGSYS 终止
# ════════════════════════════════════════════════════════════════════
# 隐藏子命令 selftest-seccomp：武装进程护栏后 (a) 报告 seccomp 过滤器是否生效，
# (b) 故意触发被拒的 socket(AF_INET)。若过滤器生效，内核按 SECCOMP_RET_KILL_PROCESS
# 以 SIGSYS 终止整个进程（父进程可感知信号退出 → Dart 侧 fail-closed）。
python3 - "$VAULT" <<'PY' || fail "seccomp 自保护验证失败"
import os, signal, subprocess, sys
vault = sys.argv[1]
env = dict(os.environ)

def run(args):
    p = subprocess.Popen([vault, "selftest-seccomp"] + args, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env)
    lines = [p.stdout.readline().decode().rstrip("\n") for _ in range(2)]
    p.wait(timeout=10)
    return lines, p.returncode

# (a) 过滤器装载报告 + (b) 网络 socket(AF_INET=2) 被拒 → SIGSYS（永不返回）
lines, rc = run([])
assert lines[0] == "ok seccomp=true", "seccomp 过滤器未生效: %r" % lines
assert lines[1] == "", "AF_INET socket 不应返回第二行: %r" % lines
assert rc == -signal.SIGSYS, "被拒网络 socket 应以 SIGSYS 终止（got %r）" % rc

# (c) 本地 socket(AF_UNIX=1) 放行——D-Bus/libsecret 依赖其工作，绝不能被误杀
lines, rc = run(["1"])
assert lines[0] == "ok seccomp=true", "seccomp 报告异常: %r" % lines
assert lines[1].startswith("ok socket(domain=1)"), "AF_UNIX 应放行: %r" % lines
assert rc == 0, "AF_UNIX 探测应正常退出（got %r）" % rc
print("ok")
PY
pass "seccomp 自保护：过滤器生效 + AF_INET socket → SIGSYS；AF_UNIX（D-Bus）放行不误杀"

# ════════════════════════════════════════════════════════════════════
# 8. Argon2id 自检（RFC 9106 §5.3 向量）
# ════════════════════════════════════════════════════════════════════
OUT=$(run selftest)
case "$OUT" in
  ok*) : ;;
  *) fail "Argon2id 自检失败: $OUT";;
esac
pass "Argon2id 自检（RFC 9106 向量）"

# ════════════════════════════════════════════════════════════════════
# 9. 用户可选 Argon2id 强度：init --kdf-* + set-kdf 重键（不丢数据）
# ════════════════════════════════════════════════════════════════════
KDF1_PW="kdf1-P@ss-强度"

# ① init-m1 --kdf-m 32768 --kdf-t 3 --kdf-p 1 → 头部槽参数反映 32768/3/1，status 同步
OUT=$(printf '%s\n' "$KDF1_PW" | "$VAULT" init-m1 "$DATA_KDF" --kdf-m 32768 --kdf-t 3 --kdf-p 1 2>&1) || true
case "$OUT" in ok\ *) : ;; *) fail "init-m1 --kdf-* 失败: $OUT";; esac
run status "$DATA_KDF" | grep -q '"kdf":{"m":32768,"t":3,"p":1}' \
  || fail "init-m1 status 应显示 kdf 32768/3/1"
python3 - "$DATA_KDF" <<'PY' || fail "init-m1 头部 KDF 参数不符"
import os, struct, sys
b = open(os.path.join(sys.argv[1], "credentials.vault"), "rb").read()
assert b[:4] == b"AVLT" and b[4] == ord("S"), "magic/version 异常"
assert b[31] == 1, "槽 kind 应为 1(口令): %r" % b[31]
assert struct.unpack_from("<III", b, 32) == (32768, 3, 1), \
    "槽 KDF 应 32768/3/1: %r" % (struct.unpack_from("<III", b, 32),)
print("ok")
PY
pass "init-m1 --kdf-m 32768 --kdf-t 3 --kdf-p 1（头部槽参数 + status 同步）"

# ② 重键前写入条目（供重键后回读比对）
python3 - "$VAULT" "$DATA_KDF" "$KDF1_PW" <<'PY' || fail "重键前 serve set/get 失败"
import base64, os, subprocess, sys
vault, data, pw = sys.argv[1:4]
def clear_lockout():
    lk = os.path.join(data, "vault.lockout")
    if os.path.exists(lk): os.remove(lk)
def handshake():
    clear_lockout()
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ))
    p.stdin.write(("handshake %s %s %s\n" % (
        base64.b64encode(os.urandom(32)).decode(), base64.b64encode(os.urandom(16)).decode(),
        base64.b64encode(pw.encode()).decode())).encode())
    p.stdin.flush()
    return p, p.stdout.readline().decode().rstrip("\n")
def cmd(p, line, payload=None):
    if payload is None: p.stdin.write((line + "\n").encode())
    else: p.stdin.write((line + "\n" + payload + "\n").encode())
    p.stdin.flush(); return p.stdout.readline().decode().rstrip("\n")
p, resp = handshake()
assert resp.startswith("ok handshake"), "正确口令应握手: %r" % resp
sec = base64.b64encode(b"kdf-entry-value").decode()
assert cmd(p, "set kugou:session", sec) == "ok", "set 失败"
assert cmd(p, "get kugou:session") == "ok " + sec, "get 回读不一致"
assert cmd(p, "quit") == "ok"; p.wait(timeout=10)
print("ok")
PY
pass "重键前 serve set/get 往返（M1）"

# ③ set-kdf --kdf-m 131072 --kdf-t 4 --kdf-p 1 → ok；头部/status 变为 131072/4/1
OUT=$(printf '%s\n' "$KDF1_PW" | "$VAULT" set-kdf "$DATA_KDF" \
        --kdf-m 131072 --kdf-t 4 --kdf-p 1 2>&1) || true
[ "$OUT" = "ok" ] || fail "set-kdf 应输出 ok: $OUT"
run status "$DATA_KDF" | grep -q '"kdf":{"m":131072,"t":4,"p":1}' \
  || fail "set-kdf 后 status 应显示 kdf 131072/4/1"
python3 - "$DATA_KDF" <<'PY' || fail "set-kdf 后头部 KDF 参数不符"
import os, struct, sys
b = open(os.path.join(sys.argv[1], "credentials.vault"), "rb").read()
assert b[31] == 1, "重键后槽 kind 应仍为口令(1): %r" % b[31]
assert struct.unpack_from("<III", b, 32) == (131072, 4, 1), \
    "重键后槽 KDF 应 131072/4/1: %r" % (struct.unpack_from("<III", b, 32),)
print("ok")
PY
pass "set-kdf --kdf-m 131072 --kdf-t 4 --kdf-p 1 → ok（头部/status 更新）"

# ④ 重键后既有条目仍可读（同值）+ trailer 篡改仍被拒
python3 - "$VAULT" "$DATA_KDF" "$KDF1_PW" <<'PY' || fail "重键后条目不可读 / trailer 篡改未拦截"
import base64, os, subprocess, sys
vault, data, pw = sys.argv[1:4]
path = os.path.join(data, "credentials.vault")
def clear_lockout():
    lk = os.path.join(data, "vault.lockout")
    if os.path.exists(lk): os.remove(lk)
def handshake():
    clear_lockout()
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ))
    p.stdin.write(("handshake %s %s %s\n" % (
        base64.b64encode(os.urandom(32)).decode(), base64.b64encode(os.urandom(16)).decode(),
        base64.b64encode(pw.encode()).decode())).encode())
    p.stdin.flush()
    return p, p.stdout.readline().decode().rstrip("\n")
def cmd(p, line, payload=None):
    if payload is None: p.stdin.write((line + "\n").encode())
    else: p.stdin.write((line + "\n" + payload + "\n").encode())
    p.stdin.flush(); return p.stdout.readline().decode().rstrip("\n")
# 重键后同一口令可解锁，且既有条目（重键前写入）仍回读同值
sec = base64.b64encode(b"kdf-entry-value").decode()
p, resp = handshake()
assert resp.startswith("ok handshake"), "重键后口令应仍可握手: %r" % resp
assert cmd(p, "get kugou:session") == "ok " + sec, "重键后条目不应丢失/损坏"
assert cmd(p, "quit") == "ok"; p.wait(timeout=10)
# trailer 篡改 → 解出 K 后 HMAC 失败（verify-before-decrypt）
pristine = open(path, "rb").read()
b = bytearray(pristine); b[-1] ^= 0x01; open(path, "wb").write(bytes(b))
p, resp = handshake()
assert resp.startswith("err"), "重键后篡改 trailer 应被拒: %r" % resp
try: p.stdin.close()
except OSError: pass
p.wait(timeout=10)
open(path, "wb").write(pristine)
print("ok")
PY
pass "set-kdf 不丢数据（既有条目同值可读）+ 重键后 trailer 篡改仍被拒"

# ⑤ set-kdf 错误口令 → SHARE_MISMATCH；vault 文件字节不变
cp "$DATA_KDF/credentials.vault" "$DATA_KDF/before_wrong.vault"
OUT=$(printf '%s\n' "definitely-wrong-pw" | "$VAULT" set-kdf "$DATA_KDF" \
        --kdf-m 65536 --kdf-t 3 --kdf-p 1 2>&1) || true
case "$OUT" in err\ SHARE_MISMATCH*) : ;; *) fail "set-kdf 错误口令应 SHARE_MISMATCH: $OUT";; esac
cmp -s "$DATA_KDF/credentials.vault" "$DATA_KDF/before_wrong.vault" \
  || fail "set-kdf 失败不应改动 vault 文件"
pass "set-kdf 错误口令 → SHARE_MISMATCH，文件不变（fail-closed 无半写）"

# ⑥ 越界 --kdf-m 在 init 即被拒（下界/上界）
for BADM in 100 99999999; do
  OUT=$(printf '%s\n' "x" | "$VAULT" init-m1 "$DATA_KDF/bad$BADM" --kdf-m "$BADM" 2>&1) || true
  case "$OUT" in err*) : ;; *) fail "越界 --kdf-m $BADM 应被拒: $OUT";; esac
done
pass "越界 --kdf-m（100 / 99999999）在 init 被快速拒绝"

# ⑦ init-m2a --kdf-m ... + set-kdf：口令+设备槽重键；恢复槽保持不变
KDF2A_PW="kdf2a-P@ss-设备"
M2AKDFOUT=$(printf '%s\n' "$KDF2A_PW" | "$VAULT" init-m2a "$DATA_KDF2A" \
              --kdf-m 32768 --kdf-t 3 --kdf-p 1 2>&1) || true
case "$M2AKDFOUT" in ok\ *) : ;; *) fail "init-m2a --kdf-* 失败: $M2AKDFOUT";; esac
KDF2A_CODE=$(printf '%s\n' "$M2AKDFOUT" | awk '{print $3}')
run status "$DATA_KDF2A" | grep -q '"kdf":{"m":32768,"t":3,"p":1}' \
  || fail "m2a init 后 status 应显示 kdf 32768/3/1"
python3 - "$DATA_KDF2A" <<'PY' || fail "m2a init 头部 KDF 参数不符"
import os, struct, sys
b = open(os.path.join(sys.argv[1], "credentials.vault"), "rb").read()
assert b[31] == 4, "槽 1 应为 PasswordDevice(4): %r" % b[31]
assert struct.unpack_from("<III", b, 32) == (32768, 3, 1), "口令+设备槽 KDF 应 32768/3/1"
assert b[122] == 3, "槽 2 应为 Recovery(3): %r" % b[122]
assert struct.unpack_from("<III", b, 123) == (0, 0, 0), "恢复槽 KDF 应为占位 0"
print("ok")
PY
OUT=$(printf '%s\n' "$KDF2A_PW" | "$VAULT" set-kdf "$DATA_KDF2A" \
        --kdf-m 131072 --kdf-t 4 --kdf-p 1 2>&1) || true
[ "$OUT" = "ok" ] || fail "m2a set-kdf 应 ok: $OUT"
run status "$DATA_KDF2A" | grep -q '"kdf":{"m":131072,"t":4,"p":1}' \
  || fail "m2a set-kdf 后 status 应显示 131072/4/1"
python3 - "$DATA_KDF2A" <<'PY' || fail "m2a set-kdf 后头部参数/恢复槽不符"
import os, struct, sys
b = open(os.path.join(sys.argv[1], "credentials.vault"), "rb").read()
assert struct.unpack_from("<III", b, 32) == (131072, 4, 1), "口令+设备槽 KDF 应 131072/4/1"
assert b[122] == 3, "恢复槽 kind 应仍为 3"
assert struct.unpack_from("<III", b, 123) == (0, 0, 0), "恢复槽 KDF 应保持占位 0（未改）"
print("ok")
PY
pass "init-m2a --kdf-* + set-kdf：口令+设备槽重键 131072/4/1；恢复槽保持占位 0"

# ⑧ m2a 重键后：口令+设备路径与恢复码路径均可解锁（同一 K，恢复槽未改）
python3 - "$VAULT" "$DATA_KDF2A" "$KDF2A_PW" "$KDF2A_CODE" <<'PY' || fail "m2a 重键后解锁/条目失败"
import base64, os, subprocess, sys
vault, data, pw, code = sys.argv[1:5]
devkey = os.path.join(data, "device.key")
pristine_dev = open(devkey, "rb").read()
def clear_lockout():
    lk = os.path.join(data, "vault.lockout")
    if os.path.exists(lk): os.remove(lk)
def handshake(secret, label=None, drop_device=False):
    clear_lockout()
    if drop_device and os.path.exists(devkey): os.remove(devkey)
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ))
    fields = [base64.b64encode(os.urandom(32)).decode(), base64.b64encode(os.urandom(16)).decode(),
              base64.b64encode(secret.encode()).decode()]
    if label is not None: fields.append(base64.b64encode(label.encode()).decode())
    try:
        p.stdin.write(("handshake " + " ".join(fields) + "\n").encode()); p.stdin.flush()
    except (BrokenPipeError, OSError):
        pass
    resp = p.stdout.readline().decode().rstrip("\n")
    if drop_device: open(devkey, "wb").write(pristine_dev)
    return p, resp
def cmd(p, line, payload=None):
    if payload is None: p.stdin.write((line + "\n").encode())
    else: p.stdin.write((line + "\n" + payload + "\n").encode())
    p.stdin.flush(); return p.stdout.readline().decode().rstrip("\n")
def close(p):
    try: p.stdin.close()
    except OSError: pass
    p.wait(timeout=10)
# 口令+设备：写入
sec = base64.b64encode(b"m2a-kdf-secret").decode()
p, resp = handshake(pw)
assert resp.startswith("ok handshake"), "m2a 重键后口令+设备应握手: %r" % resp
assert cmd(p, "set netease:cookie", sec) == "ok", "m2a 重键后 set 失败"
assert cmd(p, "quit") == "ok"; close(p)
# 恢复码（缺 device.key）：读到同一值（证明 K 未变、恢复槽未改）
p, resp = handshake(code, label="rec", drop_device=True)
assert resp.startswith("ok handshake"), "m2a 重键后恢复码应握手: %r" % resp
assert cmd(p, "get netease:cookie") == "ok " + sec, "恢复路径应读到口令路径写入的值"
assert cmd(p, "quit") == "ok"; close(p)
print("ok")
PY
pass "m2a 重键后：口令+设备 set、恢复码（缺 device.key）get 同值——恢复槽未受影响"

# ⑨ m2a 缺 device.key 时 set-kdf → NEED_RECOVERY（设备因子缺失，非爆破）
mv "$DATA_KDF2A/device.key" "$DATA_KDF2A/device.key.bak"
OUT=$(printf '%s\n' "$KDF2A_PW" | "$VAULT" set-kdf "$DATA_KDF2A" \
        --kdf-m 65536 --kdf-t 3 --kdf-p 1 2>&1) || true
case "$OUT" in err\ NEED_RECOVERY*) : ;; *) fail "m2a 缺 device.key 应 NEED_RECOVERY: $OUT";; esac
mv "$DATA_KDF2A/device.key.bak" "$DATA_KDF2A/device.key"
pass "m2a 缺 device.key 时 set-kdf → NEED_RECOVERY（引导恢复码流）"

# ⑩ crypto（含 file 后端）无常口令 KDF → set-kdf 不支持
run init-crypto "$DATA_KDFCR" >/dev/null || fail "crypto init 失败"
OUT=$(printf '%s\n' "pw" | "$VAULT" set-kdf "$DATA_KDFCR" \
        --kdf-m 65536 --kdf-t 3 --kdf-p 1 2>&1) || true
case "$OUT" in err*该模式不支持更改\ KDF*) : ;; *) fail "crypto set-kdf 应不支持: $OUT";; esac
pass "crypto/file set-kdf → err 该模式不支持更改 KDF（无口令 KDF 可重键）"

echo "全部通过 ✔"
