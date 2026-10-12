// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

namespace Archoera.Vault;

/// 解锁失败退避（credential-vault-plan §3.7「解锁失败退避/速率限制」）。
///
/// 连续解锁失败（口令错误 / 份额缺失 / 文件篡改）→ 指数退避锁定
/// （1s → 2s → … → 5min 封顶）；锁定期间 serve 握手直接拒绝（连尝试都不做），
/// 防爆破 vault / OS 安全存储 / 口令。
///
/// 状态持久化（[security-review SEC-05]）：
///   - **份额存在**（OS / LEGACY crypto / 文件密钥模式）：退避状态内嵌于
///     `master-share` 槽位值的 [ShareBundle] 中——删除退避即须销毁份额，
///     单槽后端砖化 vault、多槽后端不再有独立可删条目；
///   - **份额缺失**（口令 / 多封装模式，份额由口令或熵现场派生、不入库）：
///     回退明文文件 `<dataDir>/vault.lockout`（同用户可写——文档如实声明，
///     属此类模式的残余风险）。
///
/// 注意：仅「到达解锁阶段」的失败才计数（口令/份额/认证错误）；握手格式错误等
/// 协议噪声不计数——它们廉价且无法借此爆破密钥，避免误锁正常客户端。
///
/// 边界：本退避是 **best-effort 的在线限速**，不是机密性边界——它只约束经 `serve`
/// 的在线尝试。持有 vault 文件的攻击者可离线进行口令猜测（尾部落 HMAC / GCM 只保证
/// 完整性，不阻止离线爆破），并可删除明文 `vault.lockout` 或复制/回滚含退避状态的
/// 份额来绕过计数。真正的抗爆破来自 Argon2id 参数强度（见 [Argon2id.KdfParams]，
/// 可经 `set-kdf` 调整）。
/// **不要**据此改变退避行为（如改为 fail-closed 或加密退避状态）——那会使正常客户端
/// 在崩溃/回滚后不可用，与设计取舍不符。
public sealed class VaultLockout
{
    private const string FileName = "vault.lockout";
    private const int MaxFailures = 10;
    private const long BaseMs = 1000;
    private const long CapMs = 300_000; // 5min

    private readonly ISecretStore _store;
    private readonly string _path;

    public VaultLockout(ISecretStore store, string dataDir)
    {
        _store = store;
        _path = Path.Combine(dataDir, FileName);
    }

    /// 读取授权侧份额（内嵌于 `master-share` 槽位；兼容 legacy 32B 原始份额）。
    /// 无份额 / bundle 损坏 / 后端不可用 → null（调用方按「份额缺失」fail-closed）。
    /// 注意：不吞存储读取异常——与既有直接 `_store.Load` 语义一致，交由上层分类处理。
    public byte[]? GetShare()
    {
        var raw = _store.Load(VaultService.ShareKey);
        return ShareBundle.Decode(raw).share;
    }

    /// 写入授权侧份额（退避状态清零）——替代原先裸 `_store.Store(ShareKey, share)`。
    public void SetShare(byte[] share)
    {
        _store.Store(VaultService.ShareKey, ShareBundle.Encode(share, 0, 0));
    }

    /// 删除授权侧份额（模式迁移 / 销毁）——替代原先裸 `_store.Delete(ShareKey)`。
    public void DeleteShare()
    {
        _store.Delete(VaultService.ShareKey);
    }

    /// 锁定期间抛 [LockoutException]（附剩余秒数）；未锁定静默通过。
    public void Check()
    {
        var (_, _, _, until) = Read();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        if (until > now)
        {
            throw new LockoutException((int)Math.Max(1L, (until - now + 999) / 1000));
        }
    }

    /// 记录一次解锁失败并写入退避截止时刻（指数退避 + 封顶）。
    public void RecordFailure()
    {
        var (share, hasShare, failures, until) = Read();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        // 仅累计连续失败：已过期的历史锁定不计入
        failures = until > now ? failures + 1 : 1;
        failures = Math.Min(failures, MaxFailures);
        var backoffMs = Math.Min(BaseMs << (failures - 1), CapMs);
        Write(share, hasShare, failures, now + backoffMs);
    }

    /// 成功解锁 / 销毁重建时清零（幂等）。
    public void Clear()
    {
        var (share, hasShare, _, _) = Read();
        if (hasShare)
        {
            if (share == null) return; // bundle 损坏：不覆写，保持 fail-closed 现场
            try
            {
                _store.Store(VaultService.ShareKey, ShareBundle.Encode(share, 0, 0));
            }
            catch
            {
                // 写入失败不阻断（下次失败会覆盖状态）
            }
            return;
        }
        try
        {
            if (File.Exists(_path)) File.Delete(_path);
        }
        catch
        {
            // 清理失败不阻断（下次失败会覆盖状态）
        }
    }

    /// 读取退避状态。份额存在（槽位值非 null）→ 解析 [ShareBundle]；
    /// 份额缺失 → 明文 `vault.lockout` 回退。
    /// 返回 (share, hasShare, failures, until)：hasShare 表「槽位值存在」这一模式判定。
    private (byte[]? share, bool hasShare, int failures, long until) Read()
    {
        byte[]? raw;
        try
        {
            raw = _store.Load(VaultService.ShareKey);
        }
        catch
        {
            // 存储读取异常：回退文件状态（不阻断锁定判定）
            raw = null;
        }
        if (raw != null)
        {
            var (share, failures, until) = ShareBundle.Decode(raw);
            return (share, true, failures, until);
        }
        var (f, u) = ReadFile();
        return (null, false, f, u);
    }

    /// 写入退避状态。份额模式：在保持份额不变的前提下重编码 bundle（bundle 损坏时
    /// 保留现场不覆写）；份额缺失模式：明文文件回退（与旧版字节级兼容）。
    private void Write(byte[]? share, bool hasShare, int failures, long until)
    {
        if (hasShare)
        {
            if (share == null) return; // bundle 损坏：不覆写，保持 fail-closed 现场
            try
            {
                _store.Store(VaultService.ShareKey, ShareBundle.Encode(share, failures, until));
            }
            catch
            {
                // 写入失败不阻断（下次失败会覆盖状态）
            }
            return;
        }
        WriteFile(failures, until);
    }

    private (int failures, long until) ReadFile()
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

    private void WriteFile(int failures, long until)
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
