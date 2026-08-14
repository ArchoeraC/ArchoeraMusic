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
//   archoera-vault init <dataDir>                    → ok <b64T>   （2-of-2 拆分，S 存 OS 安全存储；
//                                                                    返回会话锚点 T，主进程须保存）
//   archoera-vault init-crypto <dataDir>             → ok <b64T>   （LEGACY 单因子：K 整体存 OS 安全存储；
//                                                                    免密 3 字段握手，推荐）
//   archoera-vault init-file <dataDir>               → ok <b64T>   （文件密钥模式：K 落盘 secret.key
//                                                                    （0600）/可被 ARCHOERA_VAULT_SECRET_KEY
//                                                                    env 覆盖，免 OS 钥匙串——headless/
//                                                                    Docker 等无 Secret Service 场景，
//                                                                    对应原 SPlayer-Next 服务端加密形态）
//   archoera-vault init-password <dataDir>           → ok <b64T>   （口令模式：S = Argon2id(password)，
//                                                                    口令经 stdin 第一行传入，绝不落 argv）
//   archoera-vault status <dataDir>                  → ok <json>   （{"initialized":true|false,"mode":"os"|"password"}）
//   archoera-vault serve <dataDir>                   → 会话模式    （§3.8：血缘校验→握手→命令循环→自退；
//                                                                    主进程 spawn 后经 stdin/stdout 通信）
//   archoera-vault destroy <dataDir>                 → ok          （删 S 份额 + vault 文件，密文不可恢复）
// 失败：stdout 输出 `err <message>` 且退出码 1（错误信息不含任何明文/密文片段）。
//
// 会话协议（serve，详见 ServeSession）：
//   主进程 → vault:    handshake <b64H> <b64C> [<b64password>]
//                      H=32B 随机会话密钥，C=16B challenge；口令模式（v2）需第 4 字段
//   vault → 主进程:    ok handshake <b64T> <b64mac>   T=16B 锚点，mac=HMAC-SHA256(H, C)
//   主进程 → vault:    get <uid> | set <uid> | delete <uid> | status | destroy | quit
//   vault → 主进程:    ok <payload> | err <message>
//
// 安全要点：
//   - 明文仅在单条命令作用域内存在，输出即清零（Set 清零调用方缓冲、Get 输出后清零）；
//   - 主密钥重建于 LockedBuffer（mlock 区），用后自动 zeroize + munlock；
//   - vault 文件/OS 存储（或口令派生）双重在场合一才能解密（2-of-2），单点泄露不足；
//   - serve 会话：握手前置（完成前不解密任何凭据）、血缘校验 + PDEATHSIG/DUMPABLE、
//     解锁失败退避（§3.7）、空闲超时自退、父死自退（§3.7/§3.8）。

const int ExitOk = 0;
const int ExitErr = 1;

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
            var ok = Argon2id.SelfTest() && DeviceEntropyFile.SelfTest();
            Console.WriteLine(ok
                ? "ok vault selftest 通过（RFC 9106 Argon2id 向量 + 设备熵密封往返）"
                : "err vault selftest 失败");
            if (!ok) return ExitErr;
            break;
        }
        case "init":
            RequireArgs(args, 2);
            {
                var svc = new VaultService(args[1]);
                svc.Init();
                // 返回会话锚点 T（主进程保存，用于后续握手校验持钥一致性）
                using (var mk = LockedBuffer.Alloc(KeySplit.KeySize))
                {
                    svc.LoadMasterKeyInto(mk.Span);
                    var t = svc.GetOrCreateAuthAnchor(mk.Span);
                    Console.WriteLine("ok " + Convert.ToBase64String(t));
                }
            }
            break;
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
        case "init-password":
            RequireArgs(args, 2);
            {
                var svc = new VaultService(args[1]);
                var password = Console.ReadLine()
                    ?? throw new ArgumentException("未读取到口令（stdin 第一行）");
                var pw = Encoding.UTF8.GetBytes(password);
                try
                {
                    svc.InitPassword(pw);
                    // 与 init 一致：返回会话锚点 T（口令仅用于本次解锁，随即清零）
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
        case "init-device":
            // 多封装（BitLocker 式，device-bound-vault-plan）：本机免密（设备熵），
            // 可选恢复口令（--set-recovery-password，stdin 第一行传入，不落 argv）。
            RequireArgs(args, 2);
            {
                var svc = new VaultService(args[1]);
                var withPassword = args.Length >= 3 && args[2] == "--set-recovery-password";
                byte[]? pw = null;
                try
                {
                    if (withPassword)
                    {
                        var password = Console.ReadLine()
                            ?? throw new ArgumentException("未读取到恢复口令（stdin 第一行）");
                        pw = Encoding.UTF8.GetBytes(password);
                    }
                    svc.InitDevice(fingerprint: null, pw);
                    // 熵路径解锁（本机免密）返回会话锚点 T
                    using (var mk = LockedBuffer.Alloc(KeySplit.KeySize))
                    {
                        svc.LoadMasterKeyInto(mk.Span, Fingerprint.Collect());
                        var t = svc.GetOrCreateAuthAnchor(mk.Span);
                        Console.WriteLine("ok " + Convert.ToBase64String(t));
                    }
                }
                finally
                {
                    if (pw != null) CryptographicOperations.ZeroMemory(pw);
                }
            }
            break;
        case "init-file":
            RequireArgs(args, 2);
            {
                // LEGACY 兼容方案（文件密钥模式）：K 整体存 dataDir/secret.key（0600），
                // 免 OS 钥匙串——无 Secret Service 的 headless Linux / Docker 可用；
                // 等价原 SPlayer-Next 服务端加密（secret.key / SPLAYER_SECRET_KEY）。
                // ARCHOERA_VAULT_SECRET_KEY（hex64）可覆盖 K（env 优先，不持久化）。
                var svc = new VaultService(args[1], new FileStore(args[1]));
                svc.InitCrypto();
                // 与 init-crypto 一致：返回会话锚点 T
                using (var mk = LockedBuffer.Alloc(KeySplit.KeySize))
                {
                    svc.LoadMasterKeyInto(mk.Span);
                    var t = svc.GetOrCreateAuthAnchor(mk.Span);
                    Console.WriteLine("ok " + Convert.ToBase64String(t));
                }
            }
            break;
        case "status":
            RequireArgs(args, 2);
            {
                var svc = new VaultService(args[1]);
                if (!svc.Initialized)
                    Console.WriteLine("ok {\"initialized\":false}");
                else if (svc.Mode == VaultMode.MultiSeal)
                    Console.WriteLine($"ok {{\"initialized\":true,\"mode\":\"multiseal\",\"backend\":\"{svc.Backend}\",\"has_recovery\":{(svc.HasRecovery ? "true" : "false")}}}");
                else
                    Console.WriteLine($"ok {{\"initialized\":true,\"mode\":\"{ModeName(svc.Mode)}\",\"backend\":\"{svc.Backend}\"}}");
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

static string ModeName(VaultMode mode) => mode switch
{
    VaultMode.Password => "password",
    VaultMode.MultiSeal => "multiseal",
    VaultMode.Crypto => "crypto",
    _ => "os",
};

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
