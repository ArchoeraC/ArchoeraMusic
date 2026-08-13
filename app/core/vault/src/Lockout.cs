namespace Archoera.Vault;

/// 解锁失败退避（credential-vault-plan §3.7「解锁失败退避/速率限制」）。
///
/// 连续解锁失败（口令错误 / 份额缺失 / 文件篡改）→ 指数退避锁定
/// （1s → 2s → … → 5min 封顶）；锁定期间 serve 握手直接拒绝（连尝试都不做），
/// 防爆破 vault / OS 安全存储 / 口令。状态持久化于 `<dataDir>/vault.lockout`
/// （非密文元数据）；成功解锁或销毁/重建 → 清零。
///
/// 注意：仅「到达解锁阶段」的失败才计数（口令/份额/认证错误）；握手格式错误等
/// 协议噪声不计数——它们廉价且无法借此爆破密钥，避免误锁正常客户端。
public sealed class VaultLockout
{
    private const string FileName = "vault.lockout";
    private const int MaxFailures = 10;
    private const long BaseMs = 1000;
    private const long CapMs = 300_000; // 5min

    private readonly string _path;

    public VaultLockout(string dataDir) => _path = Path.Combine(dataDir, FileName);

    /// 锁定期间抛 [LockoutException]（附剩余秒数）；未锁定静默通过。
    public void Check()
    {
        var (_, until) = Read();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        if (until > now)
        {
            throw new LockoutException((int)Math.Max(1L, (until - now + 999) / 1000));
        }
    }

    /// 记录一次解锁失败并写入退避截止时刻（指数退避 + 封顶）。
    public void RecordFailure()
    {
        var (failures, until) = Read();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        // 仅累计连续失败：已过期的历史锁定不计入
        failures = until > now ? failures + 1 : 1;
        failures = Math.Min(failures, MaxFailures);
        var backoffMs = Math.Min(BaseMs << (failures - 1), CapMs);
        Write(failures, now + backoffMs);
    }

    /// 成功解锁 / 销毁重建时清零（幂等）。
    public void Clear()
    {
        try
        {
            if (File.Exists(_path)) File.Delete(_path);
        }
        catch
        {
            // 清理失败不阻断（下次失败会覆盖状态）
        }
    }

    private (int failures, long until) Read()
    {
        try
        {
            if (!File.Exists(_path)) return (0, 0);
            var parts = File.ReadAllText(_path)
                .Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 2 &&
                int.TryParse(parts[0], out var f) &&
                long.TryParse(parts[1], out var u))
            {
                return (Math.Clamp(f, 0, MaxFailures), u);
            }
        }
        catch
        {
            // 读取损坏视为无锁定（下次失败覆盖）
        }
        return (0, 0);
    }

    private void Write(int failures, long until)
    {
        var dir = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var tmp = _path + ".tmp";
        File.WriteAllText(tmp, $"{failures} {until}");
        File.Move(tmp, _path, overwrite: true);
    }
}

/// 解锁锁定异常（携带剩余秒数，供主进程展示「稍后重试」）。
public sealed class LockoutException : Exception
{
    public LockoutException(int retryAfterSeconds)
        : base($"解锁失败过多，已临时锁定 {retryAfterSeconds} 秒后重试")
    {
        RetryAfterSeconds = retryAfterSeconds;
    }

    public int RetryAfterSeconds { get; }
}
