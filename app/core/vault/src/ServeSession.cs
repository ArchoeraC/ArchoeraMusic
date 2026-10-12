// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Security.Cryptography;
using System.Text;

namespace Archoera.Vault;

/// 按需会话（credential-vault-plan §3.8）：血缘校验 → 握手 → 命令循环 → 自退。
///
/// 协议（stdin/stdout 行，全部 UTF-8）：
/// ```
/// 主进程 → vault:    handshake <b64H> <b64C>            crypto（'C'）/ m2b（device.key）
///                     handshake <b64H> <b64C> <b64secret> [<b64label>]
///                     m1：secret=口令；
///                     m2a：secret=口令（+device.key），或 label=b64("rec") + secret=恢复码
///                     H=32B 随机会话密钥，C=16B challenge，各字段经 base64 传递
/// vault → 主进程:    ok handshake <b64T> <b64mac> <marker>
///                     T=16B 会话锚点（持钥证明），mac=HMAC-SHA256(H, C)，
///                     marker=构建标记（BuildInfo.Marker，PROD/TEST 版本指纹——
///                     主进程据此校验「本进程确为官方生产构建」，异常即拒绝）
/// 主进程 → vault:    get <uid> | set <uid> | delete <uid> | status | destroy | quit
///                   （set 后下一行 base64 明文负载）
/// vault → 主进程:    ok <payload> | err <message>
/// ```
///
/// 安全要点：
///   - **握手前置**：握手完成前不加载/不解密任何凭据（[VaultService] 构造仅触盘
///     读文件头；首个凭据访问发生在解锁主密钥的握手应答时刻）；
///   - 握手双因子：进程血缘（[PlatformGuard]）+ 主密钥持有（解锁成功 + 锚点回读）；
///   - 主密钥会话期持于 [LockedBuffer]（mlock），会话结束自动 zeroize + munlock；
///   - 解锁失败退避（[VaultLockout]）：失败指数退避，锁定期间连尝试都不做；
///   - 空闲超时自退（防异常常驻）、父进程死亡自退、quit 正常退出。
public sealed class ServeSession
{
    public const int HandshakeTimeoutSeconds = 10;
    public const int IdleTimeoutSeconds = 30;

    private readonly VaultService _service;
    private readonly VaultLockout _lockout;
    private readonly int _parentPid;

    public ServeSession(string dataDir)
    {
        _service = new VaultService(dataDir);
        // 与 VaultService 共用同一份退避实例（退避状态内嵌于份额槽位，SEC-05）：
        // 避免第二个 VaultLockout 视图对 bundle 读写不一致。
        _lockout = _service.Lockout;
        _parentPid = PlatformGuard.VerifyAndArm();
    }

    public int Run()
    {
        if (!_service.Initialized) return Fail("vault 未初始化，请先 init");
        var mode = _service.Mode;
        // 'S'（slots）因子模式由槽位集合推导（m1/m2a/m2b），决定握手字段数。
        var slotMode = mode == VaultMode.Slots ? _service.SlotsMode : SlotsMode.None;

        // 各模式接受的握手字段数（含命令名）：
        //   crypto（'C'）: 3；
        //   slots m1: 4；m2a: 4（口令+device.key）或 5（`rec` 标签 + 恢复码）；m2b: 3。
        int minFields, maxFields;
        if (mode == VaultMode.Slots)
        {
            (minFields, maxFields) = slotMode switch
            {
                SlotsMode.M2b => (3, 3),
                SlotsMode.M2a => (4, 5),
                _ => (4, 4),
            };
        }
        else { minFields = maxFields = 3; }

        // ── 握手（此刻才解锁主密钥；失败即拒绝，未产生任何明文）──
        string line;
        try { line = ReadLineWithTimeout(HandshakeTimeoutSeconds) ?? ""; }
        catch (TimeoutException) { return Fail("握手超时"); }
        var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < minFields || parts.Length > maxFields || parts[0] != "handshake")
        {
            return Fail(HandshakeUsage(mode, slotMode));
        }
        byte[] h, c;
        byte[]? secret = null;
        string? slotLabel = null;
        try
        {
            h = Convert.FromBase64String(parts[1]);
            c = Convert.FromBase64String(parts[2]);
            if (parts.Length >= 4) secret = Convert.FromBase64String(parts[3]);
            if (parts.Length >= 5)
                slotLabel = Encoding.UTF8.GetString(Convert.FromBase64String(parts[4]));
        }
        catch (FormatException) { return Fail("握手负载非 base64"); }
        if (h.Length != 32 || c.Length != 16) return Fail("握手负载长度错误");
        // m2a 的可选标签仅支持恢复路径（b64("rec")）
        if (slotMode == SlotsMode.M2a && slotLabel != null && slotLabel != "rec")
            return Fail("握手标签未知：m2a 仅支持 \"rec\"（恢复码）");

        // 解锁失败退避（§3.7）：锁定期间连尝试都不做（防爆破口令/OS 存储）
        try { _lockout.Check(); }
        catch (LockoutException ex) { return Fail(ex.Message); }

        using var master = LockedBuffer.Alloc(KeySplit.KeySize);
        byte[] anchor;
        try
        {
            _service.LoadMasterKeyInto(master.Span, secret, slotLabel);
            anchor = _service.GetOrCreateAuthAnchor(master.Span);
        }
        catch (NeedRecoveryException ex)
        {
            // 设备因子缺失/损坏（m2a 缺 device.key）→ 恢复流（不计入锁定退避）
            return Fail("NEED_RECOVERY " + ex.Message);
        }
        catch (VaultShareBackendMismatchException ex)
        {
            // 后端不配对（PROD/TEST 混用同一数据目录）：环境配置错误，
            // 非爆破向量——不记退避（修复路径=销毁重建，重建时 lockout 清零）
            return Fail("SHARE_BACKEND_MISMATCH " + ex.Message);
        }
        catch (VaultShareMissingException ex)
        {
            // 授权侧份额缺失：数据已不可恢复，非爆破向量——不记退避
            return Fail("SHARE_MISSING " + ex.Message);
        }
        catch (AuthenticationTagMismatchException ex)
        {
            // 份额/口令/文件不配对（GCM 认证失败，解锁主密钥或回读锚点失败）：
            // 可能为口令错误或份额被替换——爆破相关，记退避
            _lockout.RecordFailure();
            return Fail("SHARE_MISMATCH " + ex.Message);
        }
        catch (Exception ex)
        {
            // 其他解锁失败（口令错误/文件篡改等）→ 记录退避
            _lockout.RecordFailure();
            return Fail(ex.Message);
        }
        finally
        {
            if (secret != null) CryptographicOperations.ZeroMemory(secret);
        }
        _lockout.Clear();

        var mac = ComputeHmac(h, c);
        Console.WriteLine($"ok handshake {Convert.ToBase64String(anchor)} {Convert.ToBase64String(mac)} {BuildInfo.Marker}");
        Console.Out.Flush();

        // ── 命令循环（事件驱动：阻塞读 + 单次超时，无忙轮询）──
        while (true)
        {
            string? cmdLine;
            try { cmdLine = ReadLineWithTimeout(IdleTimeoutSeconds); }
            catch (TimeoutException) { return 0; } // 空闲超时自退（正常退出）
            if (cmdLine == null) return 0;         // 主进程关闭管道（正常退出）

            var result = Dispatch(cmdLine, master.Span);
            if (result == DispatchResult.Quit) return 0;
            if (result == DispatchResult.Fatal) return 1;
            // 父死自退（非忙轮询：仅在每次命令响应后顺带检测）
            if (PlatformGuard.ParentGone(_parentPid)) return 0;
        }
    }

    private enum DispatchResult { Continue, Quit, Fatal }

    private DispatchResult Dispatch(string line, ReadOnlySpan<byte> master)
    {
        var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        switch (parts[0])
        {
            case "quit":
                Console.WriteLine("ok");
                Console.Out.Flush();
                return DispatchResult.Quit;
            case "status":
                Console.WriteLine("ok {\"initialized\":true}");
                Console.Out.Flush();
                return DispatchResult.Continue;
            case "get":
                if (parts.Length != 2) { return Err("get 需要 uid 参数"); }
                return HandleGet(parts[1], master);
            case "set":
                if (parts.Length != 2) { return Err("set 需要 uid 参数"); }
                return HandleSet(parts[1], master);
            case "delete":
                if (parts.Length != 2) { return Err("delete 需要 uid 参数"); }
                return HandleDelete(parts[1], master);
            case "destroy":
                try { _service.Destroy(); }
                catch (Exception ex) { return Err(ex.Message); }
                Console.WriteLine("ok");
                Console.Out.Flush();
                return DispatchResult.Continue;
            default:
                return Err("未知命令: " + parts[0]);
        }
    }

    private DispatchResult HandleGet(string uid, ReadOnlySpan<byte> master)
    {
        byte[]? got;
        try { got = _service.GetWith(uid, master); }
        catch (Exception ex) { return Err(ex.Message); }
        if (got == null)
        {
            Console.WriteLine("ok null");
        }
        else
        {
            try { Console.WriteLine("ok " + Convert.ToBase64String(got)); }
            finally { CryptographicOperations.ZeroMemory(got); }
        }
        Console.Out.Flush();
        return DispatchResult.Continue;
    }

    private DispatchResult HandleSet(string uid, ReadOnlySpan<byte> master)
    {
        if (uid == VaultService.AuthUid) return Err("保留 uid，拒绝写入");
        string? payload;
        try { payload = ReadLineWithTimeout(IdleTimeoutSeconds); }
        catch (TimeoutException) { return Err("set 负载读取超时"); }
        if (string.IsNullOrEmpty(payload)) return Err("set 缺少 stdin 负载行（base64）");
        byte[] plain;
        try { plain = Convert.FromBase64String(payload); }
        catch (FormatException) { return Err("set 负载非 base64"); }
        try
        {
            _service.SetWith(uid, plain, master);
            Console.WriteLine("ok");
        }
        catch (Exception ex) { return Err(ex.Message); }
        finally { CryptographicOperations.ZeroMemory(plain); }
        Console.Out.Flush();
        return DispatchResult.Continue;
    }

    private DispatchResult HandleDelete(string uid, ReadOnlySpan<byte> master)
    {
        try { Console.WriteLine(_service.DeleteWith(uid, master) ? "ok true" : "ok false"); }
        catch (Exception ex) { return Err(ex.Message); }
        Console.Out.Flush();
        return DispatchResult.Continue;
    }

    private DispatchResult Err(string message)
    {
        Console.WriteLine("err " + message);
        Console.Out.Flush();
        return DispatchResult.Continue;
    }

    private int Fail(string message)
    {
        Console.WriteLine("err " + message);
        Console.Out.Flush();
        return 1;
    }

    /// 握手格式错误提示（按模式/因子模式给出精确用法）。
    private static string HandshakeUsage(VaultMode mode, SlotsMode slotMode)
    {
        if (mode == VaultMode.Slots)
            return slotMode switch
            {
                SlotsMode.M2b => "握手格式错误：m2b 需要 `handshake <b64H> <b64C>`（device.key）",
                SlotsMode.M2a => "握手格式错误：m2a 需要 `handshake <b64H> <b64C> <b64password>`"
                    + " 或 `… <b64恢复码> <b64\"rec\">`",
                _ => "握手格式错误：m1 需要 `handshake <b64H> <b64C> <b64password>`",
            };
        return "握手格式错误：需要 `handshake <b64H> <b64C>`";
    }

    /// 单次阻塞读（超时抛 [TimeoutException]；EOF 返回 null）。托管实现跨平台，无忙轮询。
    private static string? ReadLineWithTimeout(int seconds)
    {
        return Console.In.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(seconds)).GetAwaiter().GetResult();
    }

    /// HMAC-SHA256(key=H, msg=C)：一次性会话密钥，主进程可自算验证通道与存活。
    private static byte[] ComputeHmac(byte[] h, byte[] c)
    {
        using var hmac = new HMACSHA256(h);
        return hmac.ComputeHash(c);
    }
}
