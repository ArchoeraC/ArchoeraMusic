using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;

namespace Archoera.Vault;

/// OS 安全存储不可用（Linux 无 Secret Service / 无 session bus 等）。
/// 上层须明确提示降级（口令派生或禁用持久化），不静默放弃。
public sealed class SecretStoreUnavailableException : Exception
{
    public SecretStoreUnavailableException(string message) : base(message) { }
}

/// 系统授权侧份额（S）的存取抽象（credential-vault-plan §3.2）。
/// 实现：Windows DPAPI / macOS Keychain / Linux libsecret。
public interface ISecretStore
{
    /// 存储后端指纹（写入 vault 文件头，解锁时校验——防不同构建形态
    /// （PROD=OS 安全存储 / TEST=明文文件）混用同一数据目录造成份额与
    /// 凭据库永久不配对，把 GCM mismatch 升级为明确错误码）。
    string Backend { get; }

    byte[]? Load(string key);
    void Store(string key, byte[] value);
    void Delete(string key);
}

/// 平台安全存储工厂。
public static class SecretStoreFactory
{
    public static ISecretStore Create(string dataDir)
    {
        // 文件密钥模式（LEGACY 兼容方案）：库为 file 后端时按 vault 文件头分发——
        // serve/status 无需任何 env；头损坏回落默认分发（由后续指纹/解密暴露）。
        if (IsFileModeVault(dataDir)) return new FileStore(dataDir);
        // 初始化路径：vault 文件不存在时，显式 ARCHOERA_VAULT_BACKEND=file 选择
        // 文件密钥模式（等价 init-file 命令，供主进程经 env 注入启动）；已有 vault
        // 一律按文件头后端分发（env 不影响既有库，避免误伤其他后端）。
        // 置于 VAULT_TESTING insecure 分支之前：显式 backend 选择始终优先。
        if (Environment.GetEnvironmentVariable("ARCHOERA_VAULT_BACKEND") == "file"
            && !File.Exists(Path.Combine(dataDir, VaultService.VaultFileName)))
        {
            return new FileStore(dataDir);
        }
#if VAULT_TESTING
        // 测试/CI 专用明文存储（仅 VAULT_TESTING 构建编译，生产二进制不含此分支）：
        // 须显式设置环境变量才启用（绝不静默降级），用于无 Secret Service 的
        // headless 环境验证完整加解密/2-of-2/篡改链路。
        if (Environment.GetEnvironmentVariable("ARCHOERA_VAULT_INSECURE_FILE_STORE") == "1")
        {
            return new InsecureFileStore(dataDir);
        }
#endif
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            return new DpapiStore(dataDir);
        }
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            return new KeychainStore(dataDir);
        }
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
        {
            return new LibsecretStore(dataDir);
        }
        throw new SecretStoreUnavailableException("不支持的平台：无可用 OS 安全存储");
    }

    /// 判断 vault 是否为文件密钥模式（读文件头 backend=file）。
    private static bool IsFileModeVault(string dataDir)
    {
        var vaultPath = Path.Combine(dataDir, VaultService.VaultFileName);
        if (!File.Exists(vaultPath)) return false;
        try { return VaultFile.ReadHeader(vaultPath).Backend == "file"; }
        catch { return false; }
    }
}

/// 密钥环槽位作用域（修复「跨数据目录覆盖份额」根因）：
/// libsecret / Keychain 是**用户级全局命名空间**——schema/服务名 + account 槽位
/// 不区分应用数据目录，任何目录的 init 都会覆盖其他目录同一槽位的 K/S
/// （实测复现：init-crypto 目录 A → init-crypto 目录 B → 目录 A 立即
/// SHARE_MISMATCH，即用户反馈「每次重新编译后 vault 失效」的机制）。
/// 新初始化一律写入 scoped 键（含 dataDir）；升级前旧库的 legacy 键在
/// Load 时回退兼容。文件型后端（InsecureFileStore / DpapiStore）本就按
/// 目录落盘隔离，无需作用域。
internal static class SecretKeyScope
{
    public static string Scoped(string dataDir, string key) => $"{key}|{dataDir}";
}

/// 文件密钥后端（LEGACY 兼容方案，对应原 SPlayer-Next 服务端加密形态）：
/// 主密钥 K 整体落盘 <dataDir>/secret.key（0600 原子写入），**无 OS 钥匙串依赖**，
/// 适用于无 Secret Service 的 headless Linux / Docker 等场景。
///   - `ARCHOERA_VAULT_SECRET_KEY`（hex 64 = 32B）覆盖 K（对应原项目
///     SPLAYER_SECRET_KEY 语义：env 优先于文件，不持久化）；
///   - 后端指纹 backend="file"：与其他后端（libsecret/dpapi/keychain/insecure…）
///     互不配对——文件密钥库被 OS 存储后端访问 → SHARE_BACKEND_MISMATCH；
///   - 安全性：本地文件单点（弱于 OS 存储），无份额配对/无口令——选用即显式
///     接受「密钥文件泄露 = 凭据全泄露」。
public sealed class FileStore : ISecretStore
{
    private readonly string _dataDir;

    public FileStore(string dataDir) => _dataDir = dataDir;

    public string Backend => "file";

    private string KeyPath => Path.Combine(_dataDir, "secret.key");

    public byte[]? Load(string key)
    {
        // env 覆盖优先（等价原项目 SPLAYER_SECRET_KEY：env 即密钥，不落盘）
        var envKey = Environment.GetEnvironmentVariable("ARCHOERA_VAULT_SECRET_KEY");
        if (envKey != null)
        {
            try { return Convert.FromHexString(envKey); }
            catch (FormatException) { /* 非 hex64：忽略 env，回落密钥文件 */ }
        }
        if (!File.Exists(KeyPath)) return null;
        var raw = File.ReadAllBytes(KeyPath);
        return raw.Length == KeySplit.KeySize ? raw : null;
    }

    public void Store(string key, byte[] value)
    {
        Directory.CreateDirectory(_dataDir);
        // 原子写：tmp + 0600 + rename（避免进程崩溃留下半写密钥文件）
        var tmp = KeyPath + ".tmp";
        File.WriteAllBytes(tmp, value);
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(tmp, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        File.Move(tmp, KeyPath, overwrite: true);
    }

    public void Delete(string key)
    {
        if (File.Exists(KeyPath)) File.Delete(KeyPath);
    }
}

#if VAULT_TESTING
/// 测试/CI 专用明文文件存储（无任何保护，S 明文落盘 ≠ 真实安全等级）。
/// 仅编译进 VAULT_TESTING 构建（build-test.sh 产物 archoera-vault-test），
/// 生产二进制（build.sh）不含此类——测试后门不进入发布产物。
public sealed class InsecureFileStore : ISecretStore
{
    private readonly string _dir;

    public InsecureFileStore(string dataDir) => _dir = dataDir;

    /// 默认 `insecure`；测试可用 `ARCHOERA_VAULT_INSECURE_BACKEND` 覆盖后端名
    /// （模拟「不同构建形态」混用同一数据目录，验证 v4 指纹 SHARE_BACKEND_MISMATCH）。
    public string Backend =>
        Environment.GetEnvironmentVariable("ARCHOERA_VAULT_INSECURE_BACKEND") ?? "insecure";

    private string PathFor(string key) => Path.Combine(_dir, $"insecure_{key.Replace('/', '_')}.bin");

    public byte[]? Load(string key)
    {
        var p = PathFor(key);
        return File.Exists(p) ? File.ReadAllBytes(p) : null;
    }

    public void Store(string key, byte[] value)
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllBytes(PathFor(key), value);
    }

    public void Delete(string key)
    {
        var p = PathFor(key);
        if (File.Exists(p)) File.Delete(p);
    }
}
#endif

/// Windows DPAPI（CryptProtectData）：密文落盘于 dataDir/sshare.bin，
/// 密钥由系统账户/凭据绑定（Credential Guard / TPM 绑定可选加固）。
[SupportedOSPlatform("windows")]
public sealed class DpapiStore : ISecretStore
{
    private readonly string _file;

    public DpapiStore(string dataDir) => _file = Path.Combine(dataDir, "sshare.bin");

    public string Backend => "dpapi";

    public byte[]? Load(string key)
    {
        if (!File.Exists(_file)) return null;
        var raw = File.ReadAllBytes(_file);
        try
        {
            return ProtectTransforms.Unprotect(raw);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(raw);
        }
    }

    public void Store(string key, byte[] value)
    {
        var dir = Path.GetDirectoryName(_file);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        File.WriteAllBytes(_file, ProtectTransforms.Protect(value));
    }

    public void Delete(string key)
    {
        if (File.Exists(_file)) File.Delete(_file);
    }
}

/// DPAPI 转换（P/Invoke CryptProtectData/CryptUnprotectData，无第三方包依赖）。
internal static class ProtectTransforms
{
    private const uint CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public uint cbData;
        public IntPtr pbData;
    }

    public static byte[] Protect(byte[] plain)
    {
        var inBlob = new DataBlob { cbData = (uint)plain.Length, pbData = Marshal.AllocHGlobal(plain.Length) };
        try
        {
            Marshal.Copy(plain, 0, inBlob.pbData, plain.Length);
            if (!CryptProtectData(ref inBlob, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    CRYPTPROTECT_UI_FORBIDDEN, out var outBlob))
            {
                throw new InvalidOperationException($"CryptProtectData 失败（Win32={Marshal.GetLastWin32Error()}）");
            }
            return CopyBlob(outBlob);
        }
        finally
        {
            Marshal.FreeHGlobal(inBlob.pbData);
        }
    }

    public static byte[] Unprotect(byte[] cipher)
    {
        var inBlob = new DataBlob { cbData = (uint)cipher.Length, pbData = Marshal.AllocHGlobal(cipher.Length) };
        try
        {
            Marshal.Copy(cipher, 0, inBlob.pbData, cipher.Length);
            if (!CryptUnprotectData(ref inBlob, out _, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    CRYPTPROTECT_UI_FORBIDDEN, out var outBlob))
            {
                throw new InvalidOperationException($"CryptUnprotectData 失败（Win32={Marshal.GetLastWin32Error()}）");
            }
            return CopyBlob(outBlob);
        }
        finally
        {
            Marshal.FreeHGlobal(inBlob.pbData);
        }
    }

    private static byte[] CopyBlob(DataBlob blob)
    {
        try
        {
            var buf = new byte[blob.cbData];
            if (buf.Length > 0) Marshal.Copy(blob.pbData, buf, 0, buf.Length);
            return buf;
        }
        finally
        {
            if (blob.pbData != IntPtr.Zero) LocalFree(blob.pbData);
        }
    }

    [DllImport("crypt32.dll", SetLastError = true)]
    private static extern bool CryptProtectData(ref DataBlob pDataIn, string? szDataDescr,
        IntPtr pOptionalEntropy, IntPtr pvReserved, IntPtr pPromptStruct, uint dwFlags, out DataBlob pDataOut);

    [DllImport("crypt32.dll", SetLastError = true)]
    private static extern bool CryptUnprotectData(ref DataBlob pDataIn, out IntPtr ppszDataDescr,
        IntPtr pOptionalEntropy, IntPtr pvReserved, IntPtr pPromptStruct, uint dwFlags, out DataBlob pDataOut);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr hMem);
}

/// macOS Keychain（kSecClassGenericPassword）：S 存钥匙串，系统账户/钥匙串授权保护。
[SupportedOSPlatform("macos")]
public sealed class KeychainStore : ISecretStore
{
    private const string Service = "archoera.vault";
    private readonly string _dataDir;

    public KeychainStore(string dataDir) => _dataDir = dataDir;

    public string Backend => "keychain";

    /// 数据目录作用域化 account（防跨目录覆盖；见 [SecretKeyScope]）。
    private string Scoped(string key) => SecretKeyScope.Scoped(_dataDir, key);

    private static IntPtr _cfStr(string s) => CFStringCreateWithCString(IntPtr.Zero, s, 0x08000100 /* kCFStringEncodingUTF8 */);

    private static IntPtr NewDict()
    {
        var dict = CFDictionaryCreateMutable(IntPtr.Zero, 8, IntPtr.Zero, IntPtr.Zero);
        if (dict == IntPtr.Zero) throw new InvalidOperationException("CFDictionaryCreateMutable 失败");
        return dict;
    }

    private static void SetString(IntPtr dict, string key, string value)
    {
        var k = _cfStr(key);
        var v = _cfStr(value);
        CFDictionarySetValue(dict, k, v);
        CFRelease(k);
        CFRelease(v);
    }

    private static IntPtr SetData(IntPtr dict, string key, byte[] value)
    {
        var k = _cfStr(key);
        var v = Marshal.AllocHGlobal(value.Length);
        Marshal.Copy(value, 0, v, value.Length);
        var data = CFDataCreate(IntPtr.Zero, v, value.Length);
        CFDictionarySetValue(dict, k, data);
        CFRelease(k);
        CFRelease(data);
        Marshal.FreeHGlobal(v);
        return data;
    }

    public byte[]? Load(string key)
    {
        // scoped 优先；legacy 回退（升级前创建的旧库存于未作用域化槽位）
        return LoadAcct(Scoped(key)) ?? LoadAcct(key);
    }

    public void Store(string key, byte[] value)
    {
        // 覆盖写：仅删同 scoped account（绝不能删 legacy——那属于别的旧库）
        DeleteAcct(Scoped(key));
        StoreAcct(Scoped(key), value);
    }

    public void Delete(string key)
    {
        DeleteAcct(Scoped(key));
        DeleteAcct(key); // 清理升级前 legacy 槽
    }

    private byte[]? LoadAcct(string account)
    {
        var query = NewDict();
        SetString(query, "class", "genp");
        SetString(query, "svce", Service);
        SetString(query, "acct", account);
        SetString(query, "r_Data", "1");   // kSecReturnData
        SetString(query, "m_Limit", "m_LimI"); // kSecMatchLimitOne
        try
        {
            var status = SecItemCopyMatching(query, out var result);
            if (status == -25300 /* errSecItemNotFound */) return null;
            if (status != 0) throw new SecretStoreUnavailableException($"Keychain 读取失败（status={status}）");
            var len = CFDataGetLength(result);
            var buf = new byte[len];
            var data = Marshal.AllocHGlobal(len);
            try
            {
                CFDataGetBytes(result, new CFRange(0, len), data);
                Marshal.Copy(data, buf, 0, (int)len);
            }
            finally { Marshal.FreeHGlobal(data); CFRelease(result); }
            return buf;
        }
        finally { CFRelease(query); }
    }

    private void StoreAcct(string account, byte[] value)
    {
        // 覆盖写：先删同 account 旧条目（SecItemAdd 对同 service+account 返回 -25299 duplicate）
        DeleteAcct(account);
        var attrs = NewDict();
        SetString(attrs, "class", "genp");
        SetString(attrs, "svce", Service);
        SetString(attrs, "acct", account);
        SetData(attrs, "v_Data", value);
        try
        {
            var status = SecItemAdd(attrs, IntPtr.Zero);
            if (status != 0) throw new SecretStoreUnavailableException($"Keychain 写入失败（status={status}）");
        }
        finally { CFRelease(attrs); }
    }

    private void DeleteAcct(string account)
    {
        var query = NewDict();
        SetString(query, "class", "genp");
        SetString(query, "svce", Service);
        SetString(query, "acct", account);
        try { SecItemDelete(query); } finally { CFRelease(query); }
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct CFRange
    {
        public CFRange(nint location, nint length) { Location = location; Length = length; }
        public readonly nint Location;
        public readonly nint Length;
    }

    [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", CharSet = CharSet.Unicode)]
    private static extern IntPtr CFStringCreateWithCString(IntPtr allocator, string str, int encoding);

    [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
    private static extern IntPtr CFDictionaryCreateMutable(IntPtr allocator, nint capacity, IntPtr keyCallBacks, IntPtr valueCallBacks);

    [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
    private static extern void CFDictionarySetValue(IntPtr dict, IntPtr key, IntPtr value);

    [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
    private static extern void CFRelease(IntPtr cf);

    [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
    private static extern IntPtr CFDataCreate(IntPtr allocator, IntPtr bytes, nint length);

    [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
    private static extern nint CFDataGetLength(IntPtr data);

    [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
    private static extern void CFDataGetBytes(IntPtr data, CFRange range, IntPtr buffer);

    [DllImport("/System/Library/Frameworks/Security.framework/Security")]
    private static extern int SecItemAdd(IntPtr attributes, IntPtr result);

    [DllImport("/System/Library/Frameworks/Security.framework/Security")]
    private static extern int SecItemCopyMatching(IntPtr query, out IntPtr result);

    [DllImport("/System/Library/Frameworks/Security.framework/Security")]
    private static extern int SecItemDelete(IntPtr query);
}

/// Linux Secret Service（libsecret）。无 session bus（无桌面环境）时
/// [Create] 快速失败（不阻塞等待 D-Bus），上层提示降级路径。
[SupportedOSPlatform("linux")]
public sealed class LibsecretStore : ISecretStore
{
    private const string SchemaName = "archoera.vault";
    private readonly string _dataDir;

    public string Backend => "libsecret";

    public LibsecretStore(string dataDir)
    {
        _dataDir = dataDir;
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DBUS_SESSION_BUS_ADDRESS")))
        {
            throw new SecretStoreUnavailableException(
                "Linux Secret Service 不可用（无 D-Bus session bus）：凭据持久化需降级为口令派生或禁用");
        }
    }

    /// 数据目录作用域化 account（防跨目录覆盖；见 [SecretKeyScope]）。
    private string Scoped(string key) => SecretKeyScope.Scoped(_dataDir, key);

    /// SecretSchema：name + flags + 32 属性槽（此处仅 1 个 account 属性）。
    private static readonly int SchemaSize = Marshal.SizeOf<SecretSchema>();

    private sealed class Ctx
    {
        public IntPtr Schema;
        public IntPtr Hash;
        public List<IntPtr>? HGlobal = new();
    }

    private Ctx Build(string account)
    {
        var ctx = new Ctx();
        var schemaName = Marshal.StringToHGlobalAnsi(SchemaName);
        var attrName = Marshal.StringToHGlobalAnsi("account");
        ctx.HGlobal!.Add(schemaName);
        ctx.HGlobal!.Add(attrName);

        var schema = new SecretSchema
        {
            name = schemaName,
            flags = 0, // SECRET_SCHEMA_NONE
            attributes = new SecretAttribute[32],
        };
        schema.attributes[0] = new SecretAttribute { name = attrName, type = 0 /* SECRET_SCHEMA_ATTRIBUTE_STRING */ };
        ctx.Schema = Marshal.AllocHGlobal(SchemaSize);
        Marshal.StructureToPtr(schema, ctx.Schema, false);

        ctx.Hash = g_hash_table_new(IntPtr.Zero, IntPtr.Zero);
        var hashKey = Marshal.StringToHGlobalAnsi("account");
        var hashVal = Marshal.StringToHGlobalAnsi(account);
        ctx.HGlobal!.Add(hashKey);
        ctx.HGlobal!.Add(hashVal);
        g_hash_table_insert(ctx.Hash, hashKey, hashVal);
        return ctx;
    }

    private void FreeCtx(Ctx ctx)
    {
        if (ctx.Hash != IntPtr.Zero) g_hash_table_destroy(ctx.Hash);
        if (ctx.Schema != IntPtr.Zero) Marshal.FreeHGlobal(ctx.Schema);
        if (ctx.HGlobal != null)
        {
            foreach (var p in ctx.HGlobal) Marshal.FreeHGlobal(p);
            ctx.HGlobal = null;
        }
    }

    /// 释放 GLib 错误对象（GError 由 GLib 分配，须 g_error_free，否则泄漏）。
    private static void FreeError(ref IntPtr err)
    {
        if (err != IntPtr.Zero)
        {
            g_error_free(err);
            err = IntPtr.Zero;
        }
    }

    private static string ErrMsg(ref IntPtr err) =>
        err == IntPtr.Zero ? "未知错误" : (Marshal.PtrToStringAnsi(err) ?? "未知错误");

    public byte[]? Load(string key)
    {
        // scoped 优先；legacy 回退（升级前创建的旧库存于未作用域化槽位）
        return LoadAccount(Scoped(key)) ?? LoadAccount(key);
    }

    public void Store(string key, byte[] value) => StoreAccount(Scoped(key), value);

    public void Delete(string key)
    {
        DeleteAccount(Scoped(key));
        DeleteAccount(key); // 清理升级前 legacy 槽
    }

    private byte[]? LoadAccount(string account)
    {
        var ctx = Build(account);
        var err = IntPtr.Zero;
        var acc = Marshal.StringToHGlobalAnsi(account);
        var attr = Marshal.StringToHGlobalAnsi("account");
        try
        {
            // lookup_sync 为变参函数（attributes 经可变参数传、NULL 结尾），
            // P/Invoke 按固定参数个数声明：schema, cancellable, error, "account", key, NULL
            var ptr = secret_password_lookup_sync(ctx.Schema, IntPtr.Zero, out err, attr, acc, IntPtr.Zero);
            if (err != IntPtr.Zero)
            {
                throw new SecretStoreUnavailableException($"Secret Service 读取失败：{ErrMsg(ref err)}");
            }
            if (ptr == IntPtr.Zero) return null;
            try
            {
                // 份额经 Base64 存储（随机二进制不可直接走 UTF-8 字符串往返，会损坏）
                return Convert.FromBase64String(Marshal.PtrToStringAnsi(ptr)!);
            }
            finally { g_free(ptr); }
        }
        finally { FreeError(ref err); FreeCtx(ctx); Marshal.FreeHGlobal(acc); Marshal.FreeHGlobal(attr); }
    }

    private void StoreAccount(string account, byte[] value)
    {
        var ctx = Build(account);
        // 份额经 Base64 存储（随机二进制不可直接走 UTF-8 字符串往返，会损坏）
        var pass = Marshal.StringToHGlobalAnsi(Convert.ToBase64String(value));
        var label = Marshal.StringToHGlobalAnsi("archoera.vault master share");
        var err = IntPtr.Zero;
        try
        {
            // storev_sync：固定 7 参数（含 GHashTable attributes），无变参 ABI 风险
            var ok = secret_password_storev_sync(ctx.Schema, ctx.Hash, IntPtr.Zero,
                label, pass, IntPtr.Zero, out err);
            if (ok == 0)
            {
                throw new SecretStoreUnavailableException($"Secret Service 写入失败：{ErrMsg(ref err)}");
            }
        }
        finally
        {
            FreeError(ref err);
            Marshal.FreeHGlobal(pass);
            Marshal.FreeHGlobal(label);
            FreeCtx(ctx);
        }
    }

    private void DeleteAccount(string account)
    {
        var ctx = Build(account);
        var err = IntPtr.Zero;
        try { secret_password_clearv_sync(ctx.Schema, ctx.Hash, IntPtr.Zero, out err); }
        finally { FreeError(ref err); FreeCtx(ctx); }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecretAttribute
    {
        public IntPtr name;
        public int type;
    }

    /// 对齐 libsecret 的 SecretSchema（name + flags + 32 属性槽）。
    [StructLayout(LayoutKind.Sequential)]
    private struct SecretSchema
    {
        public IntPtr name;
        public int flags;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public SecretAttribute[] attributes;
    }

    [DllImport("libsecret-1.so.0")]
    private static extern int secret_password_storev_sync(IntPtr schema, IntPtr attributes, IntPtr collection, IntPtr label, IntPtr password, IntPtr cancellable, out IntPtr error);

    /// 变参函数（attributes 经可变参数传、NULL 结尾）；P/Invoke 无法声明 C varargs，
    /// 按固定参数个数声明（x86-64 下已验证读写往返正确）：schema, cancellable, error, attrName, attrValue, NULL。
    [DllImport("libsecret-1.so.0")]
    private static extern IntPtr secret_password_lookup_sync(IntPtr schema, IntPtr cancellable, out IntPtr error, IntPtr attrName, IntPtr attrValue, IntPtr sentinel);

    [DllImport("libsecret-1.so.0")]
    private static extern int secret_password_clearv_sync(IntPtr schema, IntPtr attributes, IntPtr cancellable, out IntPtr error);

    [DllImport("libglib-2.0.so.0")]
    private static extern IntPtr g_hash_table_new(IntPtr hashFunc, IntPtr keyEqualFunc);

    [DllImport("libglib-2.0.so.0")]
    private static extern void g_hash_table_insert(IntPtr hash, IntPtr key, IntPtr value);

    [DllImport("libglib-2.0.so.0")]
    private static extern void g_hash_table_destroy(IntPtr hash);

    [DllImport("libglib-2.0.so.0")]
    private static extern void g_error_free(IntPtr error);

    [DllImport("libc", EntryPoint = "free")]
    private static extern void g_free(IntPtr ptr);
}
