// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Archoera.Vault;

// 凭据保险库 CLI（按需会话进程，credential-vault-plan §3.7/§3.8）。
//
// 用法（命令走 argv——均为非密文；密文负载仅 set 经 stdin 传递）：
//   archoera-vault ping
//   archoera-vault --version                        → ok 构建标记（生产 PROD /
//                                                    测试 TEST，VaultProcess 启动校验）
//   archoera-vault selftest                          → ok          （Argon2id 自检，RFC 9106 向量）
//   archoera-vault init-crypto <dataDir>             → ok <b64T>   （LEGACY 单因子：K 整体存 OS 安全存储；
//                                                                    免密 3 字段握手，推荐）
//   archoera-vault init-file <dataDir> [--key-stdin]
//                                                    → ok <b64T>   （文件密钥模式：K 落盘 secret.key
//                                                                    （0600），免 OS 钥匙串——headless/
//                                                                    Docker 等无 Secret Service 场景，
//                                                                    对应服务端加密形态；--key-stdin 时
//                                                                    从 stdin 首行读取 hex64 K，不经 argv/env
//                                                                    ——env 注入已按 SEC-02 移除）
//   archoera-vault init-m1 <dataDir> [--kdf-m M --kdf-t T --kdf-p P]
//                                                    → ok <b64T>   （'S' slots 容器（F1 仅口令槽）：
//                                                                    自包含、无 OS 钥匙串；口令经 stdin
//                                                                    第一行传入，条目以 K 加密 + 尾部 HMAC；
//                                                                    可选 KDF 强度（非密文，缺省默认档））
//   archoera-vault init-m2a <dataDir> [--kdf-m M --kdf-t T --kdf-p P]
//                                                    → ok <b64T> <恢复码>
//                                                                   （'S' slots（F2）：口令+设备双因子槽 +
//                                                                    恢复槽；口令经 stdin 第一行，写 device.key；
//                                                                    恢复码仅此一次输出；可选 KDF 强度）
//   archoera-vault init-m2b <dataDir>                → ok <b64T>   （'S' slots（F2）：仅设备槽，写 device.key；
//                                                                    本机免密，3 字段握手）
//   archoera-vault set-kdf <dataDir> [--kdf-m M --kdf-t T --kdf-p P]
//                                                    → ok          （重键口令承载槽的 Argon2id 强度：
//                                                                    口令经 stdin 第一行；保持 K 与全部条目，
//                                                                    仅重封装口令槽并重算尾部 HMAC；m1/m2a 支持，
//                                                                    crypto/file 不支持）
//   archoera-vault status <dataDir>                  → ok <json>   （{"initialized":true|false,"mode":"crypto"|"m1"|"m2a"|"m2b"
//                                                                    [,"kdf":{"m":..,"t":..,"p":..}]}——m1/m2a 附当前强度）
//   archoera-vault serve <dataDir>                   → 会话模式    （§3.8：血缘校验→握手→命令循环→自退；
//                                                                    主进程 spawn 后经 stdin/stdout 通信）
//   archoera-vault destroy <dataDir>                 → ok          （删授权侧份额 + vault 文件，密文不可恢复）
// 失败：stdout 输出 `err <message>` 且退出码 1（错误信息不含任何明文/密文片段）。
//
// 会话协议（serve，详见 ServeSession）：
//   主进程 → vault:    handshake <b64H> <b64C> [<b64secret> [<b64label>]]
//                      H=32B 随机会话密钥，C=16B challenge；crypto（'C'）/m2b 免密 3 字段；
//                      m1 需第 4 字段（口令）；m2a 第 4 字段=口令（+device.key）
//                      或 `rec` 标签下的恢复码
//   vault → 主进程:    ok handshake <b64T> <b64mac>   T=16B 锚点，mac=HMAC-SHA256(H, C)
//   主进程 → vault:    get <uid> | set <uid> | delete <uid> | status | destroy | quit
//   vault → 主进程:    ok <payload> | err <message>
//
// 安全要点：
//   - 明文仅在单条命令作用域内存在，输出即清零（Set 清零调用方缓冲、Get 输出后清零）；
//   - 主密钥重建于 LockedBuffer（mlock 区），用后自动 zeroize + munlock；
//   - crypto：vault 文件 + OS 存储/文件密钥库双重在场合一才能解密；
//     slots：K 由槽位表封装，条目以 K 加密并以尾部 HMAC 锚定（verify-before-decrypt）；
//   - serve 会话：握手前置（完成前不解密任何凭据）、血缘校验 + PDEATHSIG/DUMPABLE、
//     解锁失败退避（§3.7）、空闲超时自退、父死自退（§3.7/§3.8）。

const int ExitOk = 0;
const int ExitErr = 1;

// Windows（含 wine 默认代码页 936/GBK）下，.NET 控制台按系统代码页编码输出
// 中文错误消息 → 主进程（Dart）按严格 UTF-8 解码即抛异常 → 协议行丢失 →
// 握手超时 → fail-closed 崩溃（2026-08-15 修复实录）。协议文本统一 UTF-8：
// 直接以原始句柄构造 UTF-8 流（AutoFlush），不依赖 SetConsoleOutputCP 的
// 「附加控制台」限制；stdin 同步置 UTF-8，保证 v2 口令（可能含非 ASCII）按
// UTF-8 读取一致。
if (OperatingSystem.IsWindows())
{
    Console.SetOut(new StreamWriter(Console.OpenStandardOutput(),
        new UTF8Encoding(false)) { AutoFlush = true });
    Console.SetError(new StreamWriter(Console.OpenStandardError(),
        new UTF8Encoding(false)) { AutoFlush = true });
    Console.SetIn(new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false)));
}

if (args.Length == 0)
{
    Console.WriteLine("err 缺少命令");
    return ExitErr;
}

try
{
    switch (args[0])
    {
        case "ping":
            Console.WriteLine("ok pong");
            break;
        case "--version":
            // 构建标记：生产产物含 PROD 标记（VaultProcess 加载前校验，
            // 防测试/被替换二进制进入应用运行时）；测试构建输出 TEST。
            Console.WriteLine(BuildInfo.Marker);
            break;
        case "selftest":
        {
            var ok = Argon2id.SelfTest();
            Console.WriteLine(ok
                ? "ok vault selftest 通过（RFC 9106 Argon2id 向量）"
                : "err vault selftest 失败");
            if (!ok) return ExitErr;
            break;
        }
        case "selftest-seccomp":
        {
            // 隐藏测试子命令（仅测试/CI 使用；编译常驻但绝不参与 serve 生命周期，
            // 生产路径无引用）。武装进程护栏后报告 seccomp 过滤器是否装载，并故意
            // 触发被拒系统调用 socket()——若过滤器生效，内核按 SECCOMP_RET_KILL_PROCESS
            // 以 SIGSYS 终止本进程，故此处不会返回；测试据此断言。
            // 可选第 2 参数 = 探测的 socket domain：默认 2（AF_INET，网络，应被 KILL）；
            // 显式传 1（AF_UNIX）验证 D-Bus/libsecret 所需的本地 socket 未被误杀（放行）。
            PlatformGuard.VerifyAndArm();
            Console.WriteLine("ok seccomp=" + (PlatformGuard.SeccompActive ? "true" : "false"));
            Console.Out.Flush();
            if (!OperatingSystem.IsLinux()) return ExitOk; // 非 Linux 无 seccomp，仅报告
            var domain = 2;
            if (args.Length >= 2 && int.TryParse(args[1], out var d)) domain = d;
            var fd = SyscallProbe.Socket(domain, 1 /*SOCK_STREAM*/, 0);
            Console.WriteLine($"ok socket(domain={domain}) 放行（fd={fd}）");
            return ExitOk;
        }
        case "init-crypto":
            RequireArgs(args, 2);
            {
                // LEGACY（crypto 传统单因子，推荐）：K 整体存 OS 安全存储，无份额配对
                var svc = new VaultService(args[1]);
                svc.InitCrypto();
                // 返回会话锚点 T（与 init 一致，主进程保存用于后续握手校验）
                using (var mk = LockedBuffer.Alloc(KeySplit.KeySize))
                {
                    svc.LoadMasterKeyInto(mk.Span);
                    var t = svc.GetOrCreateAuthAnchor(mk.Span);
                    Console.WriteLine("ok " + Convert.ToBase64String(t));
                }
            }
            break;
        case "init-m1":
            RequireArgs(args, 2);
            {
                // 'S'（slots 容器，F1 = 仅口令槽）：自包含（无需 OS 钥匙串），
                // 口令经 stdin 第一行传入，绝不落 argv；可选 KDF 强度
                // --kdf-m/--kdf-t/--kdf-p（非密文，缺省 Argon2id 默认档）。
                // 返回会话锚点 T。
                var kdf = ParseKdfFlags(args, 2);
                var svc = new VaultService(args[1], new NullSecretStore());
                var password = Console.ReadLine()
                    ?? throw new ArgumentException("未读取到口令（stdin 第一行）");
                var pw = Encoding.UTF8.GetBytes(password);
                try
                {
                    svc.InitSlots(pw, null, kdf);
                    using (var mk = LockedBuffer.Alloc(KeySplit.KeySize))
                    {
                        svc.LoadMasterKeyInto(mk.Span, pw, null);
                        var t = svc.GetOrCreateAuthAnchor(mk.Span);
                        Console.WriteLine("ok " + Convert.ToBase64String(t));
                    }
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(pw);
                }
            }
            break;
        case "init-m2a":
            RequireArgs(args, 2);
            {
                // 'S'（slots，F2 m2a = 口令+设备双因子 + 恢复槽）：口令经 stdin 传入，
                // 生成 device.key（0600）与 32B 恢复码。输出 `ok <b64锚点> <恢复码>`
                // （恢复码仅此一次可展示，供主进程提示用户妥善保存）。
                // 可选 KDF 强度 --kdf-m/--kdf-t/--kdf-p（作用于口令+设备槽）。
                var kdf = ParseKdfFlags(args, 2);
                var svc = new VaultService(args[1], new NullSecretStore());
                var password = Console.ReadLine()
                    ?? throw new ArgumentException("未读取到口令（stdin 第一行）");
                var pw = Encoding.UTF8.GetBytes(password);
                try
                {
                    var recoveryCode = svc.InitM2a(pw, null, kdf);
                    using (var mk = LockedBuffer.Alloc(KeySplit.KeySize))
                    {
                        svc.LoadMasterKeyInto(mk.Span, pw, null);
                        var t = svc.GetOrCreateAuthAnchor(mk.Span);
                        Console.WriteLine("ok " + Convert.ToBase64String(t) + " " + recoveryCode);
                    }
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(pw);
                }
            }
            break;
        case "init-m2b":
            RequireArgs(args, 2);
            {
                // 'S'（slots，F2 m2b = 仅设备槽）：无 stdin；生成 device.key（0600）
                // 后本机免密（3 字段握手）。返回会话锚点 T。
                var svc = new VaultService(args[1], new NullSecretStore());
                svc.InitM2b();
                using (var mk = LockedBuffer.Alloc(KeySplit.KeySize))
                {
                    svc.LoadMasterKeyInto(mk.Span);
                    var t = svc.GetOrCreateAuthAnchor(mk.Span);
                    Console.WriteLine("ok " + Convert.ToBase64String(t));
                }
            }
            break;
        case "init-file":
            RequireArgs(args, 2);
            {
                // LEGACY 兼容方案（文件密钥模式）：K 整体存 dataDir/secret.key（0600），
                // 免 OS 钥匙串——无 Secret Service 的 headless Linux / Docker 可用；
                // 等价服务端加密（secret.key）。
                // 可选 --key-stdin：从 stdin 第一行读取 hex64 主密钥 K（不使用 argv/env，
                // 防 /proc/<pid>/environ 泄露；见 security-review SEC-02）。
                var useStdinKey = args.Length >= 3 && args[2] == "--key-stdin";
                byte[]? injected = null;
                try
                {
                    if (useStdinKey)
                    {
                        var line = Console.ReadLine()
                            ?? throw new ArgumentException("未读取到主密钥（stdin 第一行，hex64）");
                        injected = Convert.FromHexString(line.Trim());
                        if (injected.Length != KeySplit.KeySize)
                            throw new ArgumentException($"主密钥须为 {KeySplit.KeySize * 2} 个 hex 字符");
                    }
                    var svc = new VaultService(args[1], new FileStore(args[1]));
                    svc.InitCrypto(injected);
                    // 与 init-crypto 一致：返回会话锚点 T
                    using (var mk = LockedBuffer.Alloc(KeySplit.KeySize))
                    {
                        svc.LoadMasterKeyInto(mk.Span);
                        var t = svc.GetOrCreateAuthAnchor(mk.Span);
                        Console.WriteLine("ok " + Convert.ToBase64String(t));
                    }
                }
                finally
                {
                    if (injected != null) CryptographicOperations.ZeroMemory(injected);
                }
            }
            break;
        case "status":
            RequireArgs(args, 2);
            {
                var svc = new VaultService(args[1]);
                if (!svc.Initialized)
                    Console.WriteLine("ok {\"initialized\":false}");
                else
                {
                    // m1/m2a 额外暴露当前口令承载槽的 Argon2id 强度（仅读文件头，
                    // 不解密）；crypto/m2b 无口令 KDF → 省略该字段（不破坏既有解析）。
                    var kdf = svc.CurrentKdf;
                    var kdfJson = kdf == null
                        ? string.Empty
                        : $",\"kdf\":{{\"m\":{kdf.MKiB},\"t\":{kdf.T},\"p\":{kdf.P}}}";
                    Console.WriteLine(
                        $"ok {{\"initialized\":true,\"mode\":\"{ModeName(svc)}\",\"backend\":\"{svc.Backend}\"{kdfJson}}}");
                }
            }
            break;
        case "set-kdf":
            RequireArgs(args, 2);
            {
                // 重键口令承载槽的 Argon2id 强度（口令经 stdin 第一行）。保持主密钥 K
                // 与全部条目不变，仅以新参数重新封装口令槽并重算尾部 HMAC（原子 + .bak）。
                var kdf = ParseKdfFlags(args, 2);
                var svc = new VaultService(args[1]);
                var password = Console.ReadLine()
                    ?? throw new ArgumentException("未读取到口令（stdin 第一行）");
                var pw = Encoding.UTF8.GetBytes(password);
                try
                {
                    try
                    {
                        svc.ChangeKdf(pw, kdf);
                        Console.WriteLine("ok");
                    }
                    catch (NeedRecoveryException ex)
                    {
                        // m2a 缺 device.key：设备因子不可用，转恢复码流（非爆破向量）
                        Console.WriteLine("err NEED_RECOVERY " + ex.Message);
                        return ExitErr;
                    }
                    catch (AuthenticationTagMismatchException ex)
                    {
                        // 口令错误 / 槽位篡改：GCM 认证失败 → SHARE_MISMATCH（爆破相关）
                        Console.WriteLine("err SHARE_MISMATCH " + ex.Message);
                        return ExitErr;
                    }
                    catch (InvalidOperationException ex)
                    {
                        // crypto/file/m2b：无口令 KDF 可重键
                        Console.WriteLine("err " + ex.Message);
                        return ExitErr;
                    }
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(pw);
                }
            }
            break;
        case "serve":
            RequireArgs(args, 2);
            return new ServeSession(args[1]).Run();
        case "destroy":
            RequireArgs(args, 2);
            new VaultService(args[1]).Destroy();
            Console.WriteLine("ok");
            break;
        default:
            Console.WriteLine("err 未知命令: " + args[0]);
            return ExitErr;
    }
}
catch (SecretStoreUnavailableException ex)
{
    Console.WriteLine("err " + ex.Message);
    return ExitErr;
}
catch (Exception ex)
{
    // 错误信息不携带任何明文/密文片段
    Console.WriteLine("err " + ex.GetType().Name + ": " + ex.Message);
    return ExitErr;
}
return ExitOk;

static void RequireArgs(string[] args, int n)
{
    if (args.Length < n)
    {
        throw new ArgumentException($"参数不足：需要 {n - 1} 个");
    }
}

/// 解析可选的 KDF 强度参数（`--kdf-m/--kdf-t/--kdf-p`，自 [start] 起）。
/// 均为非密文（可安全走 argv），缺省回落到 [Argon2id.KdfParams.Default]；
/// 取值经 [VaultLimits.ValidateKdf] 上下界校验，越界抛 [InvalidDataException]
/// （Program 顶层捕获 → `err …`）。
static Argon2id.KdfParams ParseKdfFlags(string[] args, int start)
{
    int? m = null, t = null, p = null;
    for (var i = start; i < args.Length; i++)
    {
        switch (args[i])
        {
            case "--kdf-m":
                m = ParseIntArg(args, ++i, "--kdf-m");
                break;
            case "--kdf-t":
                t = ParseIntArg(args, ++i, "--kdf-t");
                break;
            case "--kdf-p":
                p = ParseIntArg(args, ++i, "--kdf-p");
                break;
            default:
                throw new ArgumentException($"未知参数：{args[i]}");
        }
    }
    var d = Argon2id.KdfParams.Default;
    var kdf = new Argon2id.KdfParams(m ?? d.MKiB, t ?? d.T, p ?? d.P);
    VaultLimits.ValidateKdf(kdf.MKiB, kdf.T, kdf.P);
    return kdf;
}

/// 读取 `--kdf-*` 的整数取值（缺参/非整数均抛 [ArgumentException]）。
static int ParseIntArg(string[] args, int index, string flag)
{
    if (index >= args.Length)
        throw new ArgumentException($"{flag} 缺少取值");
    if (!int.TryParse(args[index], out var value))
        throw new ArgumentException($"{flag} 取值非整数：{args[index]}");
    return value;
}

static string ModeName(VaultService svc) => svc.Mode switch
{
    VaultMode.Crypto => "crypto",
    // 'S'（slots）：因子模式由槽位集合推导（m1 / m2a / m2b）
    VaultMode.Slots => svc.SlotsMode switch
    {
        SlotsMode.M2a => "m2a",
        SlotsMode.M2b => "m2b",
        _ => "m1",
    },
    _ => "crypto",
};

/// 测试探针（仅隐藏子命令 `selftest-seccomp` 使用）：直接调用被 seccomp 拒绝的
/// 系统调用以验证过滤器生效。生产路径不引用；在 Linux 上 libc `socket()` 即
/// 触发 socket(2) 系统调用（命中 denylist → SIGSYS）。
internal static class SyscallProbe
{
    [DllImport("libc", EntryPoint = "socket")]
    internal static extern int Socket(int domain, int type, int protocol);
}

/// 构建标记（`--version` 输出，VaultProcess 加载前校验）。
/// 生产（build.sh）输出 PROD 标记——Dart 侧默认路径解析到非 PROD 二进制
/// （测试/被替换产物）即拒绝服务；VAULT_TESTING 测试构建（build-test.sh）
/// 输出 TEST 标记，仅经显式 `ARCHOERA_VAULT_BIN` 供测试/CI 使用。
internal static class BuildInfo
{
    public static readonly string Marker =
#if VAULT_TESTING
        "ARCHOERA-VAULT-TEST-v1";
#else
        "ARCHOERA-VAULT-PROD-v1";
#endif
}
