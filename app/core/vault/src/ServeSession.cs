using System.Security.Cryptography;

namespace Archoera.Vault;

/// 按需会话（credential-vault-plan §3.8）：血缘校验 → 握手 → 命令循环 → 自退。
///
/// 协议（stdin/stdout 行，全部 UTF-8）：
/// ```
/// 主进程 → vault:    handshake <b64H> <b64C>            OS 模式
///                     handshake <b64H> <b64C> <b64password>   口令模式（v2，可选高级）
///                     H=32B 随机会话密钥，C=16B challenge，password 经 base64 传递
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
    private string? _fingerprint;

    public ServeSession(string dataDir)
    {
        _service = new VaultService(dataDir);
        _lockout = new VaultLockout(dataDir);
        _parentPid = PlatformGuard.VerifyAndArm();
    }

    public int Run()
    {
        if (!_service.Initialized) return Fail("vault 未初始化，请先 init");
        var mode = _service.Mode;
        var passwordMode = mode == VaultMode.Password;
        var multiSeal = mode == VaultMode.MultiSeal;
        _fingerprint = multiSeal ? Fingerprint.Collect() : null;

        // ── 握手（此刻才解锁主密钥；失败即拒绝，未产生任何明文）──
        string line;
        try { line = ReadLineWithTimeout(HandshakeTimeoutSeconds) ?? ""; }
        catch (TimeoutException) { return Fail("握手超时"); }
        var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        // OS: 3 字段；口令模式(v2): 4 字段；多封装(v3): 3（熵，本机免密）或 4（恢复口令）
        var okLen = passwordMode ? parts.Length == 4 : parts.Length is 3 or 4;
        if (!okLen || parts[0] != "handshake")
        {
            return Fail(passwordMode
                ? "握手格式错误：口令模式需要 `handshake <b64H> <b64C> <b64password>`"
                : multiSeal
                    ? "握手格式错误：多封装模式需要 `handshake <b64H> <b64C>` 或 `… <b64password>`（恢复）"
                    : "握手格式错误：需要 `handshake <b64H> <b64C>`");
        }
        byte[] h, c;
        byte[]? password = null;
        try
        {
            h = Convert.FromBase64String(parts[1]);
            c = Convert.FromBase64String(parts[2]);
            if (parts.Length == 4) password = Convert.FromBase64String(parts[3]);
        }
        catch (FormatException) { return Fail("握手负载非 base64"); }
        if (h.Length != 32 || c.Length != 16) return Fail("握手负载长度错误");

        // 解锁失败退避（§3.7）：锁定期间连尝试都不做（防爆破口令/OS 存储）
        try { _lockout.Check(); }
        catch (LockoutException ex) { return Fail(ex.Message); }

        using var master = LockedBuffer.Alloc(KeySplit.KeySize);
        byte[] anchor;
        try
        {
            _service.LoadMasterKeyInto(master.Span, password, _fingerprint);
            anchor = _service.GetOrCreateAuthAnchor(master.Span);
        }
        catch (NeedRecoveryException ex)
        {
            // 设备变更/熵损坏且 vault 有口令封装 → 恢复流（不计入锁定退避）
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
            if (password != null) CryptographicOperations.ZeroMemory(password);
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
                return HandleDelete(parts[1]);
            case "set-recovery-password":
                if (parts.Length != 2) { return Err("set-recovery-password 需要 base64 新口令参数"); }
                return HandleSetRecoveryPassword(parts[1], master);
            case "clear-recovery-password":
                return HandleClearRecoveryPassword(master);
            case "rebind":
                return HandleRebind(master);
            case "upgrade-device":
                // upgrade-device [--set-recovery-password <b64新口令>]：
                // v1/v2 → v3 迁移（§8）。[b64] 为恢复口令，用后清零。
                if (parts.Length is not (1 or 3) || (parts.Length == 3 && parts[1] != "--set-recovery-password"))
                {
                    return Err("upgrade-device 参数错误：可选 `--set-recovery-password <b64>`");
                }
                return HandleUpgradeDevice(
                    parts.Length == 3 ? parts[2] : null, master);
            case "clear-device-seal":
                if (parts.Length != 2) { return Err("clear-device-seal 需要 base64 恢复口令参数"); }
                return HandleClearDeviceSeal(parts[1], master);
            case "switch-mode":
                // switch-mode <os|password> [<b64新口令>]：v1 ↔ v2 份额迁移。
                // 新口令仅 v1 → v2 需要（v2 → v1 会话已解锁持 K 即可）。
                if (parts.Length is < 2 or > 3
                    || (parts[1] != "os" && parts[1] != "password"))
                {
                    return Err("switch-mode 参数错误：`switch-mode <os|password> [<b64口令>]`");
                }
                return HandleSwitchMode(parts[1], parts.Length == 3 ? parts[2] : null, master);
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

    private DispatchResult HandleDelete(string uid)
    {
        try { Console.WriteLine(_service.Delete(uid) ? "ok true" : "ok false"); }
        catch (Exception ex) { return Err(ex.Message); }
        Console.Out.Flush();
        return DispatchResult.Continue;
    }

    /// set-recovery-password：新口令 base64 经命令行传入（不落 argv 的明文），
    /// 用后清零；重密封 S 后旧口令立即失效。
    private DispatchResult HandleSetRecoveryPassword(string b64, ReadOnlySpan<byte> master)
    {
        byte[] pw;
        try { pw = Convert.FromBase64String(b64); }
        catch (FormatException) { return Err("新口令非 base64"); }
        try
        {
            _service.SetRecoveryPassword(master, pw);
        }
        catch (Exception ex)
        {
            CryptographicOperations.ZeroMemory(pw);
            return Err(ex.Message);
        }
        CryptographicOperations.ZeroMemory(pw);
        Console.WriteLine("ok");
        Console.Out.Flush();
        return DispatchResult.Continue;
    }

    private DispatchResult HandleClearRecoveryPassword(ReadOnlySpan<byte> master)
    {
        try { Console.WriteLine(_service.ClearRecoveryPassword(master) ? "ok true" : "ok false"); }
        catch (Exception ex) { return Err(ex.Message); }
        Console.Out.Flush();
        return DispatchResult.Continue;
    }

    /// clear-device-seal：关闭设备绑定（清除熵封装 + device.seal，降级 v2 口令模式）。
    /// [b64] = 当前恢复口令（base64，授权降级；口令错误 → GCM 认证失败拒绝）。
    /// 用后清零，不落 argv 明文。
    private DispatchResult HandleClearDeviceSeal(string b64, ReadOnlySpan<byte> master)
    {
        byte[] pw;
        try { pw = Convert.FromBase64String(b64); }
        catch (FormatException) { return Err("恢复口令非 base64"); }
        try
        {
            Console.WriteLine(_service.ClearDeviceSeal(master, pw) ? "ok true" : "ok false");
        }
        catch (Exception ex)
        {
            CryptographicOperations.ZeroMemory(pw);
            return Err(ex.Message);
        }
        CryptographicOperations.ZeroMemory(pw);
        Console.Out.Flush();
        return DispatchResult.Continue;
    }

    /// upgrade-device：v1/v2 → v3 迁移（§8 兼容与迁移）。
    /// [b64] 为可选恢复口令（base64，不落 argv 明文）；用后清零。
    /// 注意：升级发生在会话解锁之后（master 已持），熵路径解封不需要口令。
    private DispatchResult HandleUpgradeDevice(string? b64, ReadOnlySpan<byte> master)
    {
        byte[]? pw = null;
        if (b64 != null)
        {
            try { pw = Convert.FromBase64String(b64); }
            catch (FormatException) { return Err("恢复口令非 base64"); }
        }
        try
        {
            var id = _service.UpgradeDevice(master, _fingerprint, pw);
            Console.WriteLine("ok " + Convert.ToBase64String(id));
        }
        catch (Exception ex)
        {
            return Err(ex.Message);
        }
        finally
        {
            if (pw != null) CryptographicOperations.ZeroMemory(pw);
        }
        Console.Out.Flush();
        return DispatchResult.Continue;
    }

    /// rebind：用当前会话指纹重密封熵（换机口令恢复后调用）；成功返回新熵标识。
    private DispatchResult HandleRebind(ReadOnlySpan<byte> master)
    {
        try
        {
            var id = _service.RebindDevice(master, _fingerprint);
            Console.WriteLine("ok " + Convert.ToBase64String(id));
        }
        catch (Exception ex) { return Err(ex.Message); }
        Console.Out.Flush();
        return DispatchResult.Continue;
    }

    /// switch-mode：v1 ↔ v2 份额迁移（份额源 OS ↔ 口令，K 不变条目沿用）。
    /// [b64] 为新口令（仅 v1 → v2 需要，base64 经 stdin 行传递不落 argv 明文），用后清零。
    /// 切换成功后本会话继续可用（master 仍持）；下次握手按新模式解锁。
    private DispatchResult HandleSwitchMode(string target, string? b64, ReadOnlySpan<byte> master)
    {
        byte[]? pw = null;
        if (b64 != null)
        {
            try { pw = Convert.FromBase64String(b64); }
            catch (FormatException) { return Err("新口令非 base64"); }
        }
        try
        {
            _service.SwitchMode(master, target, pw);
            Console.WriteLine("ok");
        }
        catch (Exception ex)
        {
            return Err(ex.Message);
        }
        finally
        {
            if (pw != null) CryptographicOperations.ZeroMemory(pw);
        }
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
