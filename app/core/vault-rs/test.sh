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
# 注入面 = **可观测的蓄意破坏**：打印 err 后以专用退出码 87 终止（自毁），
# 应用侧把 87 与信号终止同等判为 crash → exit(86) 连带主程序退出（SEC-42）。
LD_PRELOAD_RC=0
LD_PRELOAD_OUT=$(LD_PRELOAD=/nonexistent/archoera-inject-test.so \
  "$VAULT" serve "$DATA_M2B" <<<'handshake AAAA BBBB' 2>/dev/null) || LD_PRELOAD_RC=$?
case "$LD_PRELOAD_OUT" in
  err*拒绝运行*) : ;;
  *) fail "LD_PRELOAD 非空应被 vault 拒绝（got: $LD_PRELOAD_OUT）";;
esac
[ "$LD_PRELOAD_RC" = "87" ] || fail "沙箱被蓄意破坏应以退出码 87 终止（got $LD_PRELOAD_RC）"
LD_AUDIT_RC=0
LD_AUDIT_OUT=$(LD_AUDIT=/nonexistent/archoera-inject-test.so \
  "$VAULT" serve "$DATA_M2B" <<<'handshake AAAA BBBB' 2>/dev/null) || LD_AUDIT_RC=$?
case "$LD_AUDIT_OUT" in
  err*拒绝运行*) : ;;
  *) fail "LD_AUDIT 非空应被 vault 拒绝（got: $LD_AUDIT_OUT）";;
esac
[ "$LD_AUDIT_RC" = "87" ] || fail "沙箱被蓄意破坏应以退出码 87 终止（got $LD_AUDIT_RC）"
pass "加载器注入拒绝（LD_PRELOAD / LD_AUDIT → err + 退出码 87：自毁并连带主程序退出）"

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

# ════════════════════════════════════════════════════════════════════
# 12. 内存护栏（mlock + zeroize）与安全落盘（符号链接 / FIFO 拒绝）
# ════════════════════════════════════════════════════════════════════
# 覆盖 docs/security-review 的 Rust 移植回归与文件系统面：
#   - R1：主密钥/明文缓冲真的 mlock（`selftest-mem` + 会话期 VmLck>0）；
#   - X1：`<file>.tmp` / `<file>.bak` 被预置为符号链接 → 拒绝写入、不穿透覆盖；
#   - X2：`<file>.tmp` 被预置为 FIFO → 拒绝写入（不得挂死在 open(O_WRONLY)）；
#   - X1c：vault 文件本身被换成符号链接 → 拒绝读取（防重定向）。

# R1-a：内存护栏自检（容器内 RLIMIT_MEMLOCK=0 时降级为「仅 zeroize」，如实跳过断言）
MEM_OUT=$("$VAULT" selftest-mem 2>&1) || fail "selftest-mem 执行失败"
case "$MEM_OUT" in ok\ memguard\ *) : ;; *) fail "selftest-mem 输出异常: $MEM_OUT";; esac
MEMLOCK_KB=$(ulimit -l 2>/dev/null || echo 0)
case "$MEM_OUT" in
  *locked=true*) pass "memguard：敏感缓冲已 mlock（selftest-mem locked=true）";;
  *) if [ "${MEMLOCK_KB:-0}" = "0" ]; then
       echo "  ！RLIMIT_MEMLOCK=0（受限环境）：memguard 降级为「仅 zeroize」，跳过 mlock 断言"
     else
       fail "RLIMIT_MEMLOCK=$MEMLOCK_KB 但 mlock 未生效: $MEM_OUT"
     fi;;
esac

# R1-b：serve 会话持锁主密钥期间 VmLck > 0；且不被相邻缓冲的 munlock 误解除
DATA_MEM="$(mktemp -d)"
run init-m1 "$DATA_MEM" >/dev/null <<<"mem-pw" || fail "内存护栏用例 init-m1 失败"
python3 - "$VAULT" "$DATA_MEM" <<'PY' || fail "会话期主密钥未保持 mlock"
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
env = dict(os.environ, ARCHOERA_VAULT_BACKEND="file")
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, env=env)
def cmd(line, payload=None):
    p.stdin.write((line + "\n" + (payload + "\n" if payload is not None else "")).encode())
    p.stdin.flush()
    return p.stdout.readline().decode().rstrip("\n")

b32 = base64.b64encode(os.urandom(32)).decode()
b16 = base64.b64encode(os.urandom(16)).decode()
assert cmd("handshake %s %s %s" % (b32, b16, base64.b64encode(b"mem-pw").decode())
           ).startswith("ok handshake")

def vmlck():
    for l in open("/proc/%d/status" % p.pid):
        if l.startswith("VmLck:"):
            return int(l.split()[1])
    return -1

assert vmlck() > 0, "会话空闲期 VmLck 应为正（主密钥页已锁）: %d" % vmlck()
assert cmd("set mem:v", base64.b64encode(b"x" * 256).decode()) == "ok"
assert cmd("get mem:v").startswith("ok ")
assert vmlck() > 0, "命令往返后主密钥页被误解锁: %d" % vmlck()
close = cmd("quit")
assert close == "ok"
p.stdin.close()
assert p.wait(timeout=15) == 0
print("ok")
PY
rm -rf "$DATA_MEM"
pass "memguard：会话期主密钥页保持 mlock（VmLck>0，命令往返不误解锁）"

# X1/X2：tmp 与 bak 被预置为符号链接 / FIFO → 拒绝写入且不穿透
DATA_FS="$(mktemp -d)"
CANARY="$(mktemp -d)/canary.txt"
printf 'ORIGINAL-CONTENT' > "$CANARY"
check_no_clobber() { # <场景名>
  [ "$(cat "$CANARY")" = "ORIGINAL-CONTENT" ] || fail "$1：canary 被覆盖（符号链接穿透写）"
  [ ! -L "$DATA_FS/credentials.vault" ] || fail "$1：vault 文件被替换为符号链接（重定向）"
}

run init-m1 "$DATA_FS" >/dev/null <<<"fs-pw" || fail "落盘用例 init-m1 失败"

# 触发一次保存（set），把 vault 应答打到 stdout。独立脚本文件 + timeout，
# 保证 FIFO 场景下旧实现（阻塞在 open(O_WRONLY)）会被 timeout 抓成失败而不是挂死。
# 因临时文件名是**进程唯一**的 `<vault>.tmp.<pid>`（并发安全，见 safefile.rs），
# 攻击面植入必须在 vault 启动后按**它自己的 pid** 落到该名上（本脚本内完成）。
WRITER="$(mktemp)"
cat > "$WRITER" <<'PYEOF'
import base64, os, subprocess, sys
vault, data = sys.argv[1:3]
plant = sys.argv[3] if len(sys.argv) > 3 else ""   # "" | symlink:<target> | fifo:
env = dict(os.environ, ARCHOERA_VAULT_BACKEND="file")
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, env=env)
def cmd(line, payload=None):
    p.stdin.write((line + "\n" + (payload + "\n" if payload is not None else "")).encode())
    p.stdin.flush()
    return p.stdout.readline().decode().rstrip("\n")
b32 = base64.b64encode(os.urandom(32)).decode()
b16 = base64.b64encode(os.urandom(16)).decode()
assert cmd("handshake %s %s %s" % (b32, b16, base64.b64encode(b"fs-pw").decode())
           ).startswith("ok handshake")
tmp = os.path.join(data, "credentials.vault.tmp.%d" % p.pid)
if plant:
    kind, _, target = plant.partition(":")
    if kind == "symlink":
        if os.path.lexists(tmp):
            os.remove(tmp)
        os.symlink(target, tmp)
    elif kind == "fifo":
        os.mkfifo(tmp)
r = cmd("set fs:x", base64.b64encode(b"value").decode())
try:
    p.stdin.close()
except OSError:
    pass
p.wait(timeout=15)
print(r)
PYEOF
SERVE_WRITE() { timeout 30 python3 "$WRITER" "$VAULT" "$DATA_FS" "$@" 2>/dev/null; }

# X1-a：实际使用的 tmp 名被植入符号链接 → 拒绝写入（不穿透覆盖、不重定向）
OUT=$(SERVE_WRITE "symlink:$CANARY") || true
case "$OUT" in err*非普通文件*) : ;; *) fail "tmp 符号链接应拒绝写入: $OUT";; esac
check_no_clobber "X1-a(tmp 符号链接)"
pass "符号链接：tmp（<vault>.tmp.<pid>）被植入符号链接 → 拒绝写入（不穿透、不重定向）"

# X2：实际使用的 tmp 名被植入 FIFO（旧实现会永久阻塞在 open(O_WRONLY)）
OUT=$(SERVE_WRITE "fifo:") || fail "FIFO 场景挂死或异常退出（保存路径不得阻塞）"
case "$OUT" in err*非普通文件*) : ;; *) fail "tmp FIFO 应拒绝写入: $OUT";; esac
pass "FIFO：tmp（<vault>.tmp.<pid>）被植入 FIFO → 拒绝写入（不挂死保存路径）"

# X1-b：bak 预置符号链接（备份为 best-effort，但绝不可穿透覆盖）
rm -f "$DATA_FS/credentials.vault.bak"
ln -s "$CANARY" "$DATA_FS/credentials.vault.bak"
OUT=$(SERVE_WRITE) || true
case "$OUT" in ok) : ;; *) fail "bak 符号链接不应影响保存本身: $OUT";; esac
check_no_clobber "X1-b(bak 符号链接)"
rm -f "$DATA_FS/credentials.vault.bak"
pass "符号链接：bak 预置为符号链接 → 不穿透（canary 未受影响）"

# X1-c：vault 文件本身被换成符号链接 → 拒绝读取
DATA_REDIR="$(mktemp -d)"
run init-m1 "$DATA_REDIR" >/dev/null <<<"redir-pw" || fail "重定向用例 init-m1 失败"
mv "$DATA_REDIR/credentials.vault" "$DATA_REDIR/real.vault"
ln -s "$DATA_REDIR/real.vault" "$DATA_REDIR/credentials.vault"
OUT=$(run status "$DATA_REDIR" 2>&1) || true
case "$OUT" in err*符号链接*) : ;; *) fail "vault 文件为符号链接时应拒绝读取: $OUT";; esac
rm -rf "$DATA_REDIR" "$DATA_FS" "$(dirname "$CANARY")"
rm -f "$WRITER"
pass "符号链接：vault 文件被替换为符号链接 → 拒绝读取（防重定向）"

# ════════════════════════════════════════════════════════════════════
# 13. 沙箱完整性（覆盖所有命令 + denylist 逐条生效）与「非自毁」语义
# ════════════════════════════════════════════════════════════════════
# 13.1 一次性命令同样硬化：`init-*` / `set-kdf` / `destroy` / `status` 也在内存里持有
#      口令与主密钥（`init-m2a` 还会打印恢复码）——必须与 serve 一样武装
#      （Seccomp 过滤器已装载 / `/proc/<pid>/mem` 不可读（dumpable=0）/ core 上限 0）。
# 13.2 denylist **逐条**生效：不只看过滤器是否装载，而是每条被拒系统调用都实际调用一次，
#      内核以 SIGSYS 终止才算生效（名单漂移 / 内核 ABI 差异会在此暴露）。
# 13.3 打爆沙箱**不自毁**：SIGKILL/SIGSEGV 活动会话、篡改/截断 vault、篡改 device.key
#      → 数据未被销毁、仍可解锁；且崩溃不产 core（RLIMIT_CORE=0 + dumpable=0）。
# 13.4 唯一的数据销毁入口是**显式** `destroy`。
DATA_SANDBOX="$(mktemp -d)"
run init-m1 "$DATA_SANDBOX" >/dev/null <<<"sandbox-pw" || fail "沙箱用例 init-m1 失败"

python3 - "$PWD/$VAULT" "$DATA_SANDBOX" <<'PY' || fail "沙箱完整性验证失败"
import base64, hashlib, os, signal, subprocess, sys, tempfile, time

vault, data = (os.path.abspath(a) for a in sys.argv[1:3])
env = dict(os.environ, ARCHOERA_VAULT_BACKEND="file")
B32 = base64.b64encode(os.urandom(32)).decode()
B16 = base64.b64encode(os.urandom(16)).decode()
PW = base64.b64encode(b"sandbox-pw").decode()
VAL = base64.b64encode(b"must-never-be-destroyed").decode()


def proc_status(pid, key):
    for l in open("/proc/%d/status" % pid):
        if l.startswith(key + ":"):
            return l.split(":", 1)[1].strip()
    return None


def limits(pid, key):
    # 形如 `Max core file size        0                    0                    bytes`
    # → tokens: Max core file size <soft> <hard> bytes
    for l in open("/proc/%d/limits" % pid):
        if l.startswith(key):
            return l.split()[4]
    return None


# ── 13.1 一次性命令硬化采样 ──
# 让 set-kdf 阻塞在「读口令」上（不发送 stdin），从而稳定采样其进程属性；
# 硬化发生在 main() 入口、任何口令/密钥进入内存之前。
p = subprocess.Popen([vault, "set-kdf", data], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE)
time.sleep(0.3)
assert p.poll() is None, "set-kdf 已退出，无法采样（预期阻塞在 stdin 读口令）"
assert proc_status(p.pid, "Seccomp") == "2", "一次性命令未装载 seccomp: %r" % proc_status(p.pid, "Seccomp")
assert limits(p.pid, "Max core file size") == "0", "一次性命令 core 上限非 0"
try:
    fd = os.open("/proc/%d/mem" % p.pid, os.O_RDONLY)
    os.close(fd)
    raise AssertionError("一次性命令的 /proc/<pid>/mem 仍可读（dumpable 未清）")
except PermissionError:
    pass
p.kill()
p.wait(timeout=30)
print("  ✓ 13.1 一次性命令（set-kdf）已硬化：seccomp=2 / mem 不可读 / core=0")

# ── 13.2 denylist 逐条生效 ──
out = subprocess.run([vault, "selftest-seccomp", "list"], stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, env=env, timeout=120)
lines = [l for l in out.stdout.decode().splitlines() if l.startswith("ok denylist")]
assert lines, "selftest-seccomp list 无输出"
txt = lines[0]
killed, total = txt.split("killed=")[1].split(" ")[0].split("/")
assert killed == total and "failed=-" in txt, "denylist 存在未生效条目: %s" % txt
print("  ✓ 13.2 denylist 逐条生效（%s 条系统调用均被 SIGSYS 终止）" % killed)

# ── 13.3 打爆沙箱不自毁 ──
def unset_lockout():
    lk = os.path.join(data, "vault.lockout")
    if os.path.exists(lk):
        os.remove(lk)


def read_value():
    unset_lockout()
    q = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env)
    q.stdin.write(("handshake %s %s %s\n" % (B32, B16, PW)).encode()); q.stdin.flush()
    hs = q.stdout.readline().decode().rstrip("\n")
    if not hs.startswith("ok handshake"):
        q.kill(); return False, hs
    q.stdin.write(b"get keep:v\n"); q.stdin.flush()
    got = q.stdout.readline().decode().rstrip("\n")
    q.stdin.write(b"quit\n"); q.stdin.flush(); q.stdout.readline()
    q.stdin.close(); q.wait(timeout=30)
    return got == "ok " + VAL, got


# 写入一条要守护的凭据
s = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, env=env)
s.stdin.write(("handshake %s %s %s\n" % (B32, B16, PW)).encode()); s.stdin.flush()
hs0 = s.stdout.readline().decode().rstrip("\n")
assert hs0.startswith("ok handshake"), "写入会话握手失败: %r（stderr=%r）" % (
    hs0, s.stderr.read(400) if s.poll() is not None else b"")
s.stdin.write(b"set keep:v\n" + VAL.encode() + b"\n"); s.stdin.flush()
r0 = s.stdout.readline().decode().rstrip("\n")
assert r0 == "ok", "写入 keep:v 失败: %r" % r0
s.stdin.write(b"quit\n"); s.stdin.flush(); s.stdout.readline()
s.stdin.close(); s.wait(timeout=30)

vault_file = os.path.join(data, "credentials.vault")
original = open(vault_file, "rb").read()

# (a) 活动会话中被 SIGKILL / SIGSEGV 打爆 → 数据仍在、仍可读、且不产 core
cwd = tempfile.mkdtemp(prefix="sandbox-core-")
for sig in (signal.SIGKILL, signal.SIGSEGV):
    t = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env, cwd=cwd)
    t.stdin.write(("handshake %s %s %s\n" % (B32, B16, PW)).encode()); t.stdin.flush()
    assert t.stdout.readline().decode().startswith("ok handshake")
    t.send_signal(sig)
    t.wait(timeout=30)
    ok, got = read_value()
    assert ok, "信号 %s 后凭据不可读（可能被销毁）: %r" % (sig, got)
    assert os.path.exists(vault_file), "vault 文件消失"
cores = [f for f in os.listdir(cwd) if f.startswith("core")]
assert not cores, "崩溃产出了 core（RLIMIT_CORE=0 未生效）: %s" % cores
print("  ✓ 13.3a SIGKILL/SIGSEGV 打爆会话：凭据仍在、仍可读、未产 core")

# (b) 篡改 / 截断 vault → serve 被拒，文件不被删除；复原后仍可读
for name, bad in (("翻转尾部字节", original[:-1] + bytes([original[-1] ^ 1])),
                  ("截断一半", original[: len(original) // 2])):
    open(vault_file, "wb").write(bad)
    q = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env)
    q.stdin.write(("handshake %s %s %s\n" % (B32, B16, PW)).encode()); q.stdin.flush()
    hs = q.stdout.readline().decode().rstrip("\n")
    q.kill(); q.wait(timeout=30)
    assert hs.startswith("err"), "%s 后应被拒: %r" % (name, hs)
    assert os.path.exists(vault_file), "%s 后 vault 文件被删除" % name
    open(vault_file, "wb").write(original)
    ok, got = read_value()
    assert ok, "复原后不可读: %r" % got
print("  ✓ 13.3b 篡改/截断 vault：被拒但未删除，复原后凭据完好")

# (c) 篡改 device.key（m2b）→ 被拒且文件未被删除（未自毁）
d2 = tempfile.mkdtemp(prefix="sandbox-m2b-")
subprocess.run([vault, "init-m2b", d2], stdout=subprocess.DEVNULL, env=env)
dk = os.path.join(d2, "device.key")
orig_dk = open(dk, "rb").read()
open(dk, "wb").write(b"\x00" * 32)
q = subprocess.Popen([vault, "serve", d2], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, env=env)
q.stdin.write(("handshake %s %s\n" % (B32, B16)).encode()); q.stdin.flush()
hs = q.stdout.readline().decode().rstrip("\n")
q.kill(); q.wait(timeout=30)
assert hs.startswith("err") and os.path.exists(dk), "篡改 device.key: %r" % hs
open(dk, "wb").write(orig_dk)
# 上面的失败握手会写入退避状态（1s 锁定）：清掉以免误判「复原后不可解锁」
lk2 = os.path.join(d2, "vault.lockout")
if os.path.exists(lk2):
    os.remove(lk2)
q = subprocess.Popen([vault, "serve", d2], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, env=env)
q.stdin.write(("handshake %s %s\n" % (B32, B16)).encode()); q.stdin.flush()
ok2 = q.stdout.readline().decode().startswith("ok handshake")
q.stdin.write(b"quit\n"); q.stdin.flush(); q.stdout.readline()
q.stdin.close(); q.wait(timeout=30)
assert ok2, "复原 device.key 后仍不可解锁"
print("  ✓ 13.3c 篡改 device.key：被拒但未删除，复原后仍可解锁")

# ── 13.4 唯一销毁入口 = 显式 destroy ──
subprocess.run([vault, "destroy", data], stdout=subprocess.DEVNULL, env=env)
left = sorted(os.listdir(data))
# 唯一允许残留的是跨进程写锁文件（`vault.lock`，内容为空、非敏感面；删除它会让互斥失效）。
assert left == ["vault.lock"], "显式 destroy 后应只剩 vault.lock: %s" % left
print("  ✓ 13.4 唯一数据销毁入口是显式 destroy（沙箱被打爆时从未销毁）")
PY
rm -rf "$DATA_SANDBOX"
# 13.5 状态文件（`vault.lockout`）被植入 **FIFO / 符号链接 / 超大文件** → 不得挂死或 OOM。
# 退避状态是 best-effort：读取走安全原语（拒绝非普通文件 + 长度上限），异常一律视为「无锁定」，
# 否则植入一个 FIFO 就能让 `read_to_string` 阻塞在 open、把 vault 卡死在握手路径（无超时覆盖）。
python3 - "$PWD/$VAULT" <<'PY' || fail "退避状态文件注入防护失败"
import base64, os, select, subprocess, sys, tempfile

vault = os.path.abspath(sys.argv[1])
env = dict(os.environ, ARCHOERA_VAULT_BACKEND="file")
B32 = base64.b64encode(bytes(range(32))).decode()
B16 = base64.b64encode(bytes(range(16))).decode()
PW = base64.b64encode(b"lockout-pw").decode()

for kind in ("fifo", "symlink", "huge"):
    d = tempfile.mkdtemp(prefix="lockout-" + kind + "-")
    subprocess.run([vault, "init-m1", d], input=b"lockout-pw\n", stdout=subprocess.DEVNULL, env=env)
    lk = os.path.join(d, "vault.lockout")
    if kind == "fifo":
        os.mkfifo(lk)
    elif kind == "symlink":
        os.symlink("/dev/zero", lk)      # 无限内容：若不设上限会 OOM / 永不结束
    else:
        open(lk, "wb").write(b"9" * 200000)
    p = subprocess.Popen([vault, "serve", d], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env)
    p.stdin.write(("handshake %s %s %s\n" % (B32, B16, PW)).encode()); p.stdin.flush()
    r, _, _ = select.select([p.stdout], [], [], 10)
    assert r, "vault.lockout=%s：握手 10s 无响应（挂死）" % kind
    line = p.stdout.readline().decode().rstrip("\n")
    assert line.startswith("ok handshake"), "vault.lockout=%s：应视为无锁定并正常解锁，得到 %r" % (kind, line)
    p.stdin.write(b"quit\n"); p.stdin.flush(); p.stdout.readline()
    p.stdin.close(); p.wait(timeout=30)
print("  ✓ 13.5 vault.lockout 被植入 FIFO / 符号链接(/dev/zero) / 超大文件 → 均正常解锁（不挂死、不 OOM）")
PY

pass "沙箱完整性 + 非自毁：所有命令硬化 / denylist 逐条生效 / 打爆沙箱不销毁数据"

# ════════════════════════════════════════════════════════════════════
# 14. 黄金夹具（golden fixtures）：容器格式与 KDF/HKDF/AEAD 语义的字节兼容锚点
# ════════════════════════════════════════════════════════════════════
# C# 版（app/core/vault/）已删除 → 字节兼容不再靠「活体 oracle 互解互读」，而靠
# **冻结夹具**（app/core/vault-rs/testdata/，由当时的实现一次性生成入库）：
# 每个夹具都必须能解开并读回固定值，且头部结构与记录一致——任何破坏读取兼容性的
# 改动都会在这里失败。重新生成仅在同名格式未变时进行（./gen_testdata.sh）。
python3 - "$PWD/$VAULT" "$PWD/testdata" <<'PY' || fail "黄金夹具验证失败"
import base64, json, os, shutil, struct, subprocess, sys, tempfile

vault, base = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
env = dict(os.environ)  # 不设 ARCHOERA_VAULT_BACKEND：夹具自带 backend 指纹，须自行配对
B32 = base64.b64encode(bytes(range(32))).decode()
B16 = base64.b64encode(bytes(range(16))).decode()


def load(name):
    """读取夹具（只读基准）→ 复制到临时目录后使用（会话会写 .bak/.lockout）。"""
    src = os.path.join(base, name)
    meta = json.load(open(os.path.join(src, "unlock.json")))
    d = tempfile.mkdtemp(prefix="golden-" + name + "-")
    shutil.copytree(src, d, dirs_exist_ok=True)
    return d, meta


def read_entries(d, fields, expect, label):
    p = subprocess.Popen([vault, "serve", d], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env)
    p.stdin.write(("handshake " + " ".join(fields) + "\n").encode()); p.stdin.flush()
    hs = p.stdout.readline().decode().rstrip("\n")
    assert hs.startswith("ok handshake"), "%s 握手失败: %r" % (label, hs)
    got = {}
    for uid in expect:
        p.stdin.write(("get %s\n" % uid).encode()); p.stdin.flush()
        r = p.stdout.readline().decode().rstrip("\n")
        got[uid] = None if r == "ok null" else base64.b64decode(r.split(" ", 1)[1]).decode()
    p.stdin.write(b"quit\n"); p.stdin.flush(); p.stdout.readline()
    p.stdin.close()
    assert p.wait(timeout=30) == 0, "%s 退出码非 0" % label
    return got


def b64(s):
    return base64.b64encode(s.encode()).decode()


def check_mode(name, d, meta, expect):
    """头部结构（模式/槽位/KDF）与条目值双向核对。"""
    raw = open(os.path.join(d, "credentials.vault"), "rb").read()
    assert raw[:4] == b"AVLT", "%s: magic 不符" % name
    mode = meta["mode"]
    assert raw[4] == (ord("C") if mode == "crypto" else ord("S")), "%s: 模式字节不符" % name
    if mode == "crypto":
        blen = raw[40]
        assert raw[41:41 + blen].decode() == meta["backend"], "%s: backend 指纹不符" % name
        got = read_entries(d, [B32, B16], expect, name)
    else:
        assert raw[29] == 1, "%s: alg 应为 1(AES-256-GCM)" % name
        n = raw[30]
        kinds, off = [], 31
        for _ in range(n):
            kinds.append(raw[off])
            m, t, p = struct.unpack_from("<III", raw, off + 1)
            wrapped_len = struct.unpack_from("<H", raw, off + 1 + 12 + 16 + 12)[0]
            off += 1 + 12 + 16 + 12 + 2 + wrapped_len
        assert kinds == meta["slot_kinds"], "%s: 槽位种类不符 %r != %r" % (name, kinds, meta["slot_kinds"])
        if meta.get("kdf"):
            m, t, p = struct.unpack_from("<III", raw, 32)
            assert [m, t, p] == [meta["kdf"]["m"], meta["kdf"]["t"], meta["kdf"]["p"]], \
                "%s: KDF 参数不符 %r" % (name, (m, t, p))
        if mode == "m1":
            got = read_entries(d, [B32, B16, b64(meta["password"])], expect, name)
        elif mode == "m2a":
            got = read_entries(d, [B32, B16, b64(meta["password"])], expect, name + "(口令)")
            assert got == expect, "%s 口令路径读出不符" % name
            got = read_entries(d, [B32, B16, b64(meta["recovery_code"]), b64("rec")],
                               expect, name + "(恢复码)")
        else:  # m2b：仅设备槽
            got = read_entries(d, [B32, B16], expect, name)
    assert got == expect, "%s 读出不符: %r" % (name, got)
    print("  ✓ 14 %s（%s）：%s + 两条目一致" % (
        name, meta["mode"], {"crypto": "'C' 头/backend 冻结",
                             "m1": "口令槽 + KDF 冻结",
                             "m2a": "pwdev/recovery 两条 HKDF",
                             "m2b": "device HKDF"}[meta["mode"]]))


for name in ("crypto-file", "m1", "m2a", "m2b"):
    d, meta = load(name)
    check_mode(name, d, meta, meta["entries"])
    shutil.rmtree(d, ignore_errors=True)
print("ok")
PY
pass "黄金夹具：4 模式容器格式与 KDF/HKDF/AEAD 语义锚点（读回固定值）"

# ════════════════════════════════════════════════════════════════════
# 15. 写入侧容量上限：单条 / 整库超限必须**落盘前拒绝**（不得写成「下次加载即被拒」的自锁）
# ════════════════════════════════════════════════════════════════════
# 回归实测过的可用性自毁：只在加载侧校验时，一次 4096 KiB 明文 `set` 会「回 ok」，
# 但库此后无法加载（只能靠 .bak 救）；累计 >16 MiB 同理。现两处都在写入侧前置校验。
DATA_CAP="$(mktemp -d)"
run init-m1 "$DATA_CAP" >/dev/null <<<"cap-pw" || fail "容量用例 init-m1 失败"
python3 - "$PWD/$VAULT" "$DATA_CAP" <<'PY' || fail "写入侧容量上限验证失败"
import base64, os, subprocess, sys

vault, data = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
env = dict(os.environ, ARCHOERA_VAULT_BACKEND="file")
B32 = base64.b64encode(bytes(range(32))).decode()
B16 = base64.b64encode(bytes(range(16))).decode()
PW = base64.b64encode(b"cap-pw").decode()
MAX_ENTRY = 4 * 1024 * 1024
TAG = 16


def session():
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env)
    p.stdin.write(("handshake %s %s %s\n" % (B32, B16, PW)).encode()); p.stdin.flush()
    assert p.stdout.readline().decode().startswith("ok handshake"), "解锁失败（库被自锁？）"
    return p


def cmd(p, line, payload=None):
    p.stdin.write((line + "\n" + (payload + "\n" if payload is not None else "")).encode())
    p.stdin.flush()
    return p.stdout.readline().decode().rstrip("\n")


def close(p):
    try:
        p.stdin.write(b"quit\n"); p.stdin.flush(); p.stdout.readline()
    except Exception:
        pass
    p.stdin.close(); p.wait(timeout=60)


p = session()
# 边界：明文上限 = 4 MiB − 16B（GCM tag）→ 恰达上限应成功
r_ok = cmd(p, "set keep:limit", base64.b64encode(b"a" * (MAX_ENTRY - TAG)).decode())
assert r_ok == "ok", "明文恰达上限应写入成功: %r" % r_ok
# 覆盖成小值腾出空间
assert cmd(p, "set keep:limit", base64.b64encode(b"b").decode()) == "ok"
# 越界 +1B → 必须拒绝
r_bad = cmd(p, "set over:limit", base64.b64encode(b"a" * (MAX_ENTRY - TAG + 1)).decode())
assert r_bad.startswith("err") and "过大" in r_bad, "单条超限应拒绝: %r" % r_bad
# 超限尝试后库仍可加载（未自锁）
assert cmd(p, "get over:limit") == "ok null", "超限条目不应落库"
# 累计超整库上限 → 拒绝（且此前已写入的条目仍在）
val = base64.b64encode(os.urandom(1536 * 1024)).decode()
last = ""
for i in range(1, 14):
    last = cmd(p, "set fill:%d" % i, val)
    if not last.startswith("ok"):
        break
assert "容量上限" in last, "整库超限应以「容量上限」拒绝: %r" % last
close(p)

p = session()          # 关键回归：整库超限后仍能解锁（此前为「文件过大…拒绝加载」）
assert cmd(p, "get fill:1").startswith("ok "), "既有条目应完好"
close(p)
print("  ✓ 15 写入侧容量：单条边界（%d B 通过 / +1B 拒绝）与整库上限均落盘前拒绝，未自锁"
      % (MAX_ENTRY - TAG))
PY
rm -rf "$DATA_CAP"
pass "写入侧容量上限：单条/整库超限落盘前拒绝（不再出现「写完即无法加载」的自锁）"

# ════════════════════════════════════════════════════════════════════
# 16. 并发语义：**兼容并发**（跨进程写锁）而非「最后写者获胜」
# ════════════════════════════════════════════════════════════════════
# 16a 锁原语：外部进程持 `vault.lock` 独占锁时，vault 的写命令必须**阻塞等待**（内核事件唤醒，
#     非轮询），释放后立即完成；崩溃自动释放（无需人工清理）。
# 16b 丢失更新：`set-kdf`（重键）与另一会话的 `set` 交错时，后者必须基于**重键后**的状态保存，
#     否则会把旧 KDF 头部写回（重键被静默回滚）。无锁实现下该用例会失败。
DATA_CONC="$(mktemp -d)"
run init-m1 "$DATA_CONC" >/dev/null <<<"conc-pw" || fail "并发用例 init-m1 失败"
python3 - "$PWD/$VAULT" "$DATA_CONC" <<'PY' || fail "并发语义验证失败"
import base64, fcntl, os, select, subprocess, sys, threading, time

vault, data = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
env = dict(os.environ, ARCHOERA_VAULT_BACKEND="file")
B32 = base64.b64encode(bytes(range(32))).decode()
B16 = base64.b64encode(bytes(range(16))).decode()
PW = base64.b64encode(b"conc-pw").decode()
LOCK = os.path.join(data, "vault.lock")


def session():
    p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env)
    p.stdin.write(("handshake %s %s %s\n" % (B32, B16, PW)).encode()); p.stdin.flush()
    assert p.stdout.readline().decode().startswith("ok handshake"), "解锁失败"
    return p


def cmd(p, line, payload=None):
    p.stdin.write((line + "\n" + (payload + "\n" if payload is not None else "")).encode())
    p.stdin.flush()
    return p.stdout.readline().decode().rstrip("\n")


def close(p):
    try:
        p.stdin.write(b"quit\n"); p.stdin.flush(); p.stdout.readline()
    except Exception:
        pass
    p.stdin.close(); p.wait(timeout=60)


# ── 16a 锁原语：外部持锁 → 写命令阻塞；释放 → 完成 ──
# 注意：握手路径里的「取/建锚点」也会取一次锁（读-改-写），故外部持锁必须**在握手之后**再拿，
# 否则会先卡在握手（那是锁生效的另一种表现，但会让本用例测不到 set 的阻塞）。
assert os.path.exists(LOCK), "锁文件应在首次写入后存在: %s" % LOCK
p = session()
holder = open(LOCK, "r+b")
fcntl.flock(holder.fileno(), fcntl.LOCK_EX)      # 模拟另一进程持锁
result = {}
resumed = threading.Event()

def do_set():
    result["r"] = cmd(p, "set lock:probe", base64.b64encode(b"v").decode())
    resumed.set()

t = threading.Thread(target=do_set); t.start()
blocked = not resumed.wait(timeout=0.8)          # 0.8s 内不应完成
fcntl.flock(holder.fileno(), fcntl.LOCK_UN)
holder.close()
t.join(timeout=30)
assert blocked, "外部持锁期间写命令竟已完成（锁未生效）"
assert result.get("r") == "ok", "释放锁后写命令应完成: %r" % result.get("r")
close(p)
print("  ✓ 16a 跨进程写锁：外部持锁时写命令阻塞等待，释放后立即完成（无轮询）")

# ── 16b 丢失更新：CLI 重键（慢，持锁数百 ms～秒）与并发 serve 写入交错，二者都必须保留 ──
# `set-kdf` 是 CLI 命令（不在 serve 协议内），但要持同一把写锁；若无锁，serve 侧会基于
# 「重键前」的状态保存 → 把旧 KDF 头部写回（重键被静默回滚）。有锁则 serve 侧等待后基于新状态保存。
new_kdf = {"m": 131072, "t": 4, "p": 1}
p_set = session()
r1, r2 = {}, {}

def rekey():
    r1["p"] = subprocess.run(
        [vault, "set-kdf", data, "--kdf-m", str(new_kdf["m"]),
         "--kdf-t", str(new_kdf["t"]), "--kdf-p", str(new_kdf["p"])],
        input=b"conc-pw\n", stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=300)
    r1["out"] = r1["p"].stdout.decode(errors="replace").strip()

def setter():
    time.sleep(0.15)          # 让重键先拿到锁
    r2["r"] = cmd(p_set, "set conc:after", base64.b64encode(b"kept").decode())

t1 = threading.Thread(target=rekey); t2 = threading.Thread(target=setter)
t1.start(); t2.start(); t1.join(); t2.join()
assert r1["p"].returncode == 0 and r1["out"].startswith("ok"), "重键应成功: rc=%d %r" % (
    r1["p"].returncode, r1["out"])
assert r2["r"] == "ok", "并发 set 应成功: %r" % r2["r"]
close(p_set)

# 校验：新 KDF 参数**与**新条目同时存在（否则说明发生了丢失更新）
import struct
raw = open(os.path.join(data, "credentials.vault"), "rb").read()
m, t, pp = struct.unpack_from("<III", raw, 32)
assert (m, t, pp) == (new_kdf["m"], new_kdf["t"], new_kdf["p"]), \
    "重键被丢失更新回滚：头部 KDF=%r" % ((m, t, pp),)
p = session()
got = cmd(p, "get conc:after")
assert got.startswith("ok ") and base64.b64decode(got.split(" ", 1)[1]) == b"kept", \
    "并发写入的条目丢失: %r" % got
close(p)
print("  ✓ 16b 无丢失更新：重键头部（%d/%d/%d）与并发写入的条目同时保留" % (m, t, pp))
PY
rm -rf "$DATA_CONC"
pass "并发语义：兼容并发（阻塞式跨进程写锁）——无丢失更新、崩溃自动释放、不引入轮询"

echo "全部通过 ✔"