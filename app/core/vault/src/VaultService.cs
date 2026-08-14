using System.Security.Cryptography;

namespace Archoera.Vault;

/// 设备熵路径解锁失败（指纹不符 / device.seal 缺失 / 熵被篡改）且 vault 具备
/// 口令封装——主进程应转「恢复口令」流（serve 应答 `err NEED_RECOVERY`）。
/// 不是解锁失败：不计入锁定退避（设备变更/熵损坏是恢复场景，非爆破尝试）。
public sealed class NeedRecoveryException : Exception
{
    public NeedRecoveryException(string message) : base(message) { }
}

/// 份额后端不配对（v4）：vault 文件头记录的 backend 指纹 ≠ 当前实际存储后端。
/// 根因：不同构建形态（PROD=OS 安全存储 / TEST=明文文件）混用同一数据目录，
/// 造成 S 份额与凭据库永久不配对（此前表现为模糊的 GCM mismatch）。
/// 非爆破向量：不记锁定退避；主进程应识别 `SHARE_BACKEND_MISMATCH` 引导销毁重建。
public sealed class VaultShareBackendMismatchException : Exception
{
    public string StoredBackend { get; }
    public string CurrentBackend { get; }

    public VaultShareBackendMismatchException(string stored, string current)
        : base($"份额存储后端不配对：vault 记录 [{stored}]，当前为 [{current}]——"
               + "不同构建形态混用同一数据目录所致，请销毁重建 vault")
    {
        StoredBackend = stored;
        CurrentBackend = current;
    }
}

/// 授权侧份额（S）缺失：vault 文件存在但对应后端无份额。
/// 非爆破向量：不记锁定退避；主进程应识别 `SHARE_MISSING` 引导销毁重建
/// （原份额不可恢复）。
public sealed class VaultShareMissingException : Exception
{
    public string Backend { get; }

    public VaultShareMissingException(string backend)
        : base($"授权侧份额（S）缺失（后端 [{backend}]）：vault 无法解密，需销毁重建")
    {
        Backend = backend;
    }
}

/// vault 服务（命令语义）：init / init-password / init-device / serve / destroy / status。
///
/// 主密钥 K 永不落盘：文件头只存 K_vault = K ⊕ S（vault 侧份额），
/// S（授权侧份额）锚定于 OS 安全存储（默认）或 Argon2id 口令派生（高级）；
/// 解密时两侧协同重建 K，短时持有于 [LockedBuffer]（mlock + 用后 zeroize）。
public sealed class VaultService
{
    public const string VaultFileName = "credentials.vault";
    public const string ShareKey = "master-share";
    public const string DeviceSealFileName = "device.seal";

    /// 会话锚点条目 uid（§3.8 握手）：vault 生成 16B 随机 T 经主密钥加密存此条目，
    /// 握手时解密回读交主进程保存——后续会话比对该值以确认「仍是同一把 K 的 vault」。
    public const string AuthUid = "__auth__";

    private readonly string _dataDir;
    private readonly ISecretStore _store;
    private readonly VaultLockout _lockout;

    public VaultService(string dataDir) : this(dataDir, null) { }

    /// [store] 注入用于显式选择后端（如文件密钥模式 init-file 直接给 FileStore；
    /// null → 工厂按 vault 文件头/env/平台自动分发）。
    public VaultService(string dataDir, ISecretStore? store)
    {
        _dataDir = dataDir;
        _store = store ?? SecretStoreFactory.Create(dataDir);
        _lockout = new VaultLockout(dataDir);
    }

    public string VaultPath => Path.Combine(_dataDir, VaultFileName);

    public string DeviceSealPath => Path.Combine(_dataDir, DeviceSealFileName);

    /// 当前份额后端（v4 指纹：file/dpapi/keychain/libsecret/insecure…）。
    /// status 命令据此暴露，供主进程区分「OS 安全存储 crypto」与
    /// 「文件密钥模式（file）」——两者模式同为 crypto 但安全性不同。
    public string Backend => _store.Backend;

    public bool Initialized => File.Exists(VaultPath);

    /// 份额锚定模式（读文件头判定；未初始化视为 OS 模式）。
    public VaultMode Mode => Initialized ? VaultFile.ReadHeader(VaultPath).Mode : VaultMode.OsStore;

    /// 初始化（OS 模式）：生成主密钥 K 并 2-of-2 拆分，S 存 OS 安全存储。
    /// 失败回滚（授权侧写入失败时不残留半初始化 vault）。
    public void Init()
    {
        if (Initialized) throw new InvalidOperationException("vault 已初始化，请先 destroy");
        _lockout.Clear();
        var (keyVault, share) = KeySplit.Split();
        try
        {
            _store.Store(ShareKey, share);
            // v4：写入当前后端指纹（解锁时校验，防 PROD/TEST 混用数据目录）
            VaultFile.Create(keyVault, _store.Backend).Save(VaultPath);
        }
        catch
        {
            if (File.Exists(VaultPath)) File.Delete(VaultPath);
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(keyVault);
            CryptographicOperations.ZeroMemory(share);
        }
    }

    /// 初始化（LEGACY：crypto 传统单因子，推荐）：主密钥 K 整体存 OS 安全存储
    /// （DPAPI/Keychain/libsecret），vault 文件不含密钥材料（key_vault=32B 零占位）。
    /// 与 OS 模式（v1/v4，2-of-2 拆分）相比无份额配对、无口令、无设备熵，
    /// 稳定性更高（不存在份额丢失导致的凭据整体丢失）；安全性降为单点
    /// （OS 钥匙串被攻破 = 凭据全泄露）。
    /// 失败回滚（授权侧写入失败时不残留半初始化 vault）。
    public void InitCrypto()
    {
        if (Initialized) throw new InvalidOperationException("vault 已初始化，请先 destroy");
        _lockout.Clear();
        var master = RandomNumberGenerator.GetBytes(KeySplit.KeySize);
        try
        {
            _store.Store(ShareKey, master); // K 整体入 OS 安全存储
            VaultFile.CreateCrypto(_store.Backend).Save(VaultPath);
        }
        catch
        {
            if (File.Exists(VaultPath)) File.Delete(VaultPath);
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(master);
        }
    }

    /// 初始化（口令模式，可选高级）：S 份额 = Argon2id(password, salt)。
    /// 口令绝不落盘/落 argv；salt 与 KDF 参数随文件头存储。
    /// [password] 用后由调用方清零（本方法仅读取）。
    public void InitPassword(byte[] password, byte[]? salt = null)
    {
        if (Initialized) throw new InvalidOperationException("vault 已初始化，请先 destroy");
        _lockout.Clear();
        salt ??= RandomNumberGenerator.GetBytes(VaultFile.SaltSize);
        var kdf = Argon2id.KdfParams.Default;
        var share = Argon2id.Derive(password, salt, [], [], kdf.MKiB, kdf.T, kdf.P, KeySplit.KeySize);
        var keyVault = new byte[KeySplit.KeySize];
        var master = RandomNumberGenerator.GetBytes(KeySplit.KeySize);
        try
        {
            for (var i = 0; i < KeySplit.KeySize; i++)
                keyVault[i] = (byte)(master[i] ^ share[i]);
            VaultFile.CreatePassword(keyVault, salt, kdf).Save(VaultPath);
        }
        catch
        {
            if (File.Exists(VaultPath)) File.Delete(VaultPath);
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(keyVault);
            CryptographicOperations.ZeroMemory(share);
            CryptographicOperations.ZeroMemory(master);
        }
    }

    /// 初始化（多封装模式，BitLocker 式，device-bound-vault-plan §3）：
    /// S 份额被设备熵（kind=2）与可选恢复口令（kind=1）分别密封，任一方可解。
    /// 熵本体存 device.seal（指纹密封）；口令仅经 stdin 传入，绝不落盘/落 argv。
    /// [fingerprint] 为 null 时自动采集（[Fingerprint.Collect]）。
    public void InitDevice(string? fingerprint, byte[]? recoveryPassword)
    {
        if (Initialized) throw new InvalidOperationException("vault 已初始化，请先 destroy");
        _lockout.Clear();
        fingerprint ??= Fingerprint.Collect();
        if (fingerprint == null)
        {
            throw new InvalidOperationException("无法采集设备指纹（设备熵路径不可用，请改用口令模式）");
        }
        var (keyVault, share) = KeySplit.Split();
        var entropy = RandomNumberGenerator.GetBytes(DeviceEntropyFile.EntropySize);
        var device = DeviceEntropyFile.Create();
        try
        {
            device.SealAndSave(DeviceSealPath, entropy, fingerprint);
            var kSeal = DeviceEntropyFile.ShareSealKey(entropy);
            try
            {
                var seals = new List<VaultSeal>
                {
                    SealShareWithEntropy(share, kSeal, device.EntropyId),
                };
                if (recoveryPassword != null)
                {
                    var salt = RandomNumberGenerator.GetBytes(VaultFile.SaltSize);
                    seals.Insert(0, SealShareWithPassword(share, recoveryPassword, salt,
                        Argon2id.KdfParams.Default));
                }
                VaultFile.CreateMultiSeal(keyVault, seals).Save(VaultPath);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(kSeal);
            }
        }
        catch
        {
            if (File.Exists(VaultPath)) File.Delete(VaultPath);
            if (File.Exists(DeviceSealPath)) File.Delete(DeviceSealPath);
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(keyVault);
            CryptographicOperations.ZeroMemory(share);
            CryptographicOperations.ZeroMemory(entropy);
        }
    }

    // ── S 份额密封（v3 多封装）──────────────────────────────────────

    /// 口令封装：key = Argon2id(口令)，KDF 参数随封装块存储。
    public static VaultSeal SealShareWithPassword(
        byte[] share, byte[] password, byte[] salt, Argon2id.KdfParams kdf)
    {
        var key = Argon2id.Derive(password, salt, [], [], kdf.MKiB, kdf.T, kdf.P, KeySplit.KeySize);
        try
        {
            var nonce = RandomNumberGenerator.GetBytes(VaultFile.NonceSize);
            var ct = new byte[share.Length + VaultFile.TagSize];
            using var gcm = new AesGcm(key, VaultFile.TagSize);
            var tag = ct.AsSpan(share.Length);
            gcm.Encrypt(nonce, share, ct.AsSpan(0, share.Length), tag);
            return new VaultSeal
            {
                Kind = SealKind.Password, Salt = salt, Kdf = kdf, Nonce = nonce, Ciphertext = ct,
            };
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
        }
    }

    /// 设备熵封装：key = K_seal（[DeviceEntropyFile.ShareSealKey]，由熵派生）。
    public static VaultSeal SealShareWithEntropy(byte[] share, byte[] kSeal, byte[] entropyId)
    {
        var nonce = RandomNumberGenerator.GetBytes(VaultFile.NonceSize);
        var ct = new byte[share.Length + VaultFile.TagSize];
        using var gcm = new AesGcm(kSeal, VaultFile.TagSize);
        var tag = ct.AsSpan(share.Length);
        gcm.Encrypt(nonce, share, ct.AsSpan(0, share.Length), tag);
        return new VaultSeal
        {
            Kind = SealKind.DeviceEntropy, EntropyId = entropyId, Nonce = nonce, Ciphertext = ct,
        };
    }

    /// 解封 S 份额（返回 32B；调用方用后须 zeroize）。
    public static byte[] UnsealShare(VaultSeal seal, byte[] key)
    {
        var share = new byte[KeySplit.KeySize];
        using var gcm = new AesGcm(key, VaultFile.TagSize);
        var tag = seal.Ciphertext.AsSpan(share.Length);
        gcm.Decrypt(seal.Nonce, seal.Ciphertext.AsSpan(0, share.Length), tag, share);
        return share;
    }

    /// 协同重建主密钥到调用方缓冲（须为 [LockedBuffer] 的 mlock 区，用后自动清零）。
    /// OS 模式：[password] 必须为 null；口令模式（v2）：[password] 必须提供；
    /// 多封装（v3）：[password] 提供 → 口令恢复路径，否则 → 设备熵路径
    /// （熵失败且 vault 有口令封装 → 抛 [NeedRecoveryException]，serve 转 NEED_RECOVERY）。
    /// 授权侧份额（S）读入普通堆后立即清零；重建结果落于锁定内存，不进可换页堆。
    public void LoadMasterKeyInto(Span<byte> dest, byte[]? password, string? fingerprint)
    {
        var vault = VaultFile.Load(VaultPath);
        if (vault.Mode == VaultMode.Password)
        {
            if (password == null)
                throw new InvalidOperationException("口令模式：解锁需要口令（握手第 4 字段）");
            var kdf = vault.Kdf ?? throw new InvalidDataException("口令模式 vault 缺少 KDF 参数");
            var share = Argon2id.Derive(password, vault.Salt!, [], [],
                kdf.MKiB, kdf.T, kdf.P, KeySplit.KeySize);
            try
            {
                KeySplit.Recombine(vault.KeyVault, share, dest);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(share);
            }
            return;
        }
        if (vault.Mode == VaultMode.MultiSeal)
        {
            if (password != null)
            {
                // 恢复路径：口令解封（口令错误 → GCM 认证失败，serve 记退避）
                var seal = vault.Seals.FirstOrDefault(s => s.Kind == SealKind.Password)
                    ?? throw new InvalidOperationException("vault 无口令封装，无法用口令解锁");
                var key = Argon2id.Derive(password, seal.Salt!, [], [],
                    seal.Kdf!.MKiB, seal.Kdf.T, seal.Kdf.P, KeySplit.KeySize);
                try
                {
                    var share = UnsealShare(seal, key);
                    try { KeySplit.Recombine(vault.KeyVault, share, dest); }
                    finally { CryptographicOperations.ZeroMemory(share); }
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(key);
                }
                return;
            }

            // 主路径：设备熵解锁（本机免密，一次 HKDF+AES-GCM，无 Argon2id）
            fingerprint ??= Fingerprint.Collect();
            if (fingerprint == null || !File.Exists(DeviceSealPath))
            {
                throw new NeedRecoveryException(
                    "设备熵不可用（缺 device.seal 或无法采集指纹）：请输入恢复口令");
            }
            byte[] entropy;
            try
            {
                entropy = DeviceEntropyFile.Load(DeviceSealPath).Unseal(fingerprint);
            }
            catch (Exception ex) when (ex is CryptographicException or InvalidDataException)
            {
                // 指纹不符 / 熵文件损坏 → 有口令封装则可恢复
                if (vault.Seals.Any(s => s.Kind == SealKind.Password))
                    throw new NeedRecoveryException("设备标识已变更或熵文件损坏：" + ex.Message);
                throw;
            }
            var seal2 = vault.Seals.FirstOrDefault(s => s.Kind == SealKind.DeviceEntropy)
                ?? throw new InvalidOperationException("vault 无设备熵封装");
            var kSeal = DeviceEntropyFile.ShareSealKey(entropy);
            try
            {
                var share = UnsealShare(seal2, kSeal);
                try { KeySplit.Recombine(vault.KeyVault, share, dest); }
                finally { CryptographicOperations.ZeroMemory(share); }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(kSeal);
                CryptographicOperations.ZeroMemory(entropy);
            }
            return;
        }
        // LEGACY（crypto 传统单因子）：K 整体存 OS 安全存储，无份额配对——
        // 后端指纹照常校验（防 PROD/TEST 混用数据目录），取回即主密钥。
        if (vault.Mode == VaultMode.Crypto)
        {
            if (vault.Backend != null && vault.Backend != _store.Backend)
            {
                throw new VaultShareBackendMismatchException(vault.Backend, _store.Backend);
            }
            var kCrypto = _store.Load(ShareKey)
                ?? throw new VaultShareMissingException(_store.Backend);
            try
            {
                kCrypto.CopyTo(dest);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(kCrypto);
            }
            return;
        }
        // v4 后端指纹校验：文件头记录的后端 ≠ 当前实际后端 → 份额不配对
        // （PROD/TEST 混用同一数据目录的典型症状），升级为明确异常而非 GCM mismatch。
        // 旧版 v1/v2/v3 文件 Backend=null → 跳过校验（向后兼容）。
        if (vault.Backend != null && vault.Backend != _store.Backend)
        {
            throw new VaultShareBackendMismatchException(vault.Backend, _store.Backend);
        }
        var shareOs = _store.Load(ShareKey)
            ?? throw new VaultShareMissingException(_store.Backend);
        try
        {
            KeySplit.Recombine(vault.KeyVault, shareOs, dest);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(shareOs);
        }
    }

    /// OS 模式便捷重载（既有调用路径）。
    public void LoadMasterKeyInto(Span<byte> dest) => LoadMasterKeyInto(dest, null, null);

    /// 多封装模式便捷重载（熵路径，本机免密）。
    public void LoadMasterKeyInto(Span<byte> dest, string? fingerprint)
        => LoadMasterKeyInto(dest, null, fingerprint);

    // ── 恢复口令 / 设备绑定管理（须已解锁：持 K）────────────────────

    /// 设置/修改恢复口令（多封装）：用新口令重密封 S，替换 kind=1 封装。
    /// 旧口令立即失效（v3 解封是「新口令密封 S」，非多口令并存）。
    public void SetRecoveryPassword(ReadOnlySpan<byte> master, byte[] newPassword)
    {
        var vault = VaultFile.Load(VaultPath);
        if (vault.Mode != VaultMode.MultiSeal)
            throw new InvalidOperationException("仅多封装模式（设备绑定）支持恢复口令");
        var salt = RandomNumberGenerator.GetBytes(VaultFile.SaltSize);
        var newSeal = SealShareWithPassword(RecoverShare(vault, master), newPassword, salt,
            Argon2id.KdfParams.Default);
        var idx = vault.Seals.FindIndex(s => s.Kind == SealKind.Password);
        if (idx >= 0) vault.Seals[idx] = newSeal;
        else vault.Seals.Insert(0, newSeal);
        vault.Save(VaultPath);
    }

    /// 清除恢复口令（多封装）：删除 kind=1 封装——换机/熵丢失后不可恢复
    /// （只能销毁重建），调用方须在 UI 明确提示该后果。
    /// 返回是否实际清除了。
    public bool ClearRecoveryPassword(ReadOnlySpan<byte> master)
    {
        var vault = VaultFile.Load(VaultPath);
        if (vault.Mode != VaultMode.MultiSeal)
            throw new InvalidOperationException("仅多封装模式（设备绑定）支持恢复口令");
        var idx = vault.Seals.FindIndex(s => s.Kind == SealKind.Password);
        if (idx < 0) return false;
        vault.Seals.RemoveAt(idx);
        vault.Save(VaultPath);
        return true;
    }

    /// 关闭设备绑定（清除熵封装，回落口令模式）：删除 kind=2 封装 + device.seal，
    /// vault 降级为 v2（口令模式）——此后每次解锁需口令（v2 语义，device-bound-vault-plan
    /// §1.3「关闭 = 清除设备熵封装，改纯口令」）。
    /// [password] 语义按封装状态分流：
    ///   - 有恢复口令封装（kind=1）：须为当前恢复口令，经解密 kind=1 验证授权
    ///     （口令错误 → GCM 认证失败即拒绝，不触发锁定退避——本命令不属爆破入口）；
    ///   - 无恢复口令封装（纯熵绑定，开启时免密）：为调用方新设的 v2 口令，
    ///     免授权校验——与「免密开启」对称（设备已攻破时 v3 凭据本就可读，
    ///     关闭不额外降低安全性）。
    /// 注意：v3 口令封装的解密密钥（Argon2id 派生）≠ 被封装的随机份额 S_rand，
    /// 故降级 v2 后（S' = Argon2id(口令)）必须用 K' = key_vault ⊕ S' 重加密全部条目
    /// （原条目以 K = key_vault ⊕ S_rand 加密）。
    public bool ClearDeviceSeal(ReadOnlySpan<byte> master, byte[] password)
    {
        var vault = VaultFile.Load(VaultPath);
        if (vault.Mode != VaultMode.MultiSeal)
            throw new InvalidOperationException("非设备绑定模式，无需关闭");
        byte[] salt;
        Argon2id.KdfParams kdf;
        VaultSeal? seal = vault.Seals.FirstOrDefault(s => s.Kind == SealKind.Password);
        if (seal != null)
        {
            // 有恢复口令封装：复用其 salt/kdf，先验证口令（GCM 认证失败拒绝）
            salt = seal.Salt!;
            kdf = seal.Kdf!;
        }
        else
        {
            // 纯熵绑定：新 salt + 默认 KDF 构建 v2 布局
            salt = RandomNumberGenerator.GetBytes(VaultFile.SaltSize);
            kdf = Argon2id.KdfParams.Default;
        }
        var sPrime = Argon2id.Derive(password, salt, [], [], kdf.MKiB, kdf.T, kdf.P, KeySplit.KeySize);
        try
        {
            if (seal != null)
            {
                // 授权校验：用派生密钥解密 kind=1 封装得原 S_rand（口令错误 → GCM 拒绝）
                var sRand = UnsealShare(seal, sPrime);
                CryptographicOperations.ZeroMemory(sRand);
            }
            byte[]? k2 = null;
            try
            {
                // 新分享关系：K' = key_vault ⊕ S'（S' = Argon2id(口令)，v2 语义）
                k2 = new byte[KeySplit.KeySize];
                for (var i = 0; i < KeySplit.KeySize; i++)
                    k2[i] = (byte)(vault.KeyVault[i] ^ sPrime[i]);
                var v2 = VaultFile.CreatePassword(vault.KeyVault, salt, kdf);
                foreach (var e in vault.Entries)
                {
                    var plain = vault.Decrypt(e, master);          // 用 K 解密
                    try { v2.Entries.Add(v2.Encrypt(e.Uid, plain, k2)); } // 用 K' 重加密
                    finally { CryptographicOperations.ZeroMemory(plain); }
                }
                v2.Save(VaultPath);
                if (File.Exists(DeviceSealPath)) File.Delete(DeviceSealPath);
            }
            finally
            {
                if (k2 != null) CryptographicOperations.ZeroMemory(k2);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(sPrime);
        }
        return true;
    }

    /// 设备绑定（v3）是否设置了恢复口令封装（kind=1）——决定关闭绑定是
    /// 「验证恢复口令」还是「新设 v2 口令」。非 multiseal 返回 false。
    public bool HasRecovery =>
        VaultFile.Load(VaultPath) is { Mode: VaultMode.MultiSeal } v
            && v.Seals.Any(s => s.Kind == SealKind.Password);

    /// 升级为设备绑定（v1/v2 → v3，§8 兼容与迁移）：
    /// v1（OS 模式）/ v2（口令模式）已有 vault 解锁后补建 v3 多封装——
    /// 生成熵 E 写 device.seal（当前指纹），用熵密封 S 得 kind=2 封装；
    /// [recoveryPassword] 非 null 时另建 kind=1 口令封装（换机恢复路径）。
    /// key_vault 与 K 均不变 → 既有条目无需重加密（与 ClearDeviceSeal 的
    /// 降级重加密相反）。v1 的 OS 份额仍保留（§8「可选项」），v3 模式
    /// 解锁只走熵/口令路径。
    /// 失败回滚：vault 写入失败时删除 device.seal（防熵文件残留半升级）。
    /// 返回新熵标识（entropy_id）。
    public byte[] UpgradeDevice(ReadOnlySpan<byte> master, string? fingerprint, byte[]? recoveryPassword)
    {
        var vault = VaultFile.Load(VaultPath);
        if (vault.Mode == VaultMode.MultiSeal)
            throw new InvalidOperationException("已为设备绑定模式（multiseal），无需升级");
        fingerprint ??= Fingerprint.Collect();
        if (fingerprint == null)
            throw new InvalidOperationException("无法采集设备指纹（设备熵路径不可用，请先启用系统标识）");
        var share = RecoverShare(vault, master);
        var entropy = RandomNumberGenerator.GetBytes(DeviceEntropyFile.EntropySize);
        var device = DeviceEntropyFile.Create();
        try
        {
            device.SealAndSave(DeviceSealPath, entropy, fingerprint);
            var kSeal = DeviceEntropyFile.ShareSealKey(entropy);
            try
            {
                var seals = new List<VaultSeal>
                {
                    SealShareWithEntropy(share, kSeal, device.EntropyId),
                };
                if (recoveryPassword != null)
                {
                    var salt = RandomNumberGenerator.GetBytes(VaultFile.SaltSize);
                    seals.Insert(0, SealShareWithPassword(share, recoveryPassword, salt,
                        Argon2id.KdfParams.Default));
                }
                var v3 = VaultFile.CreateMultiSeal(vault.KeyVault, seals);
                v3.Entries.AddRange(vault.Entries); // K 不变：条目原样沿用
                v3.Save(VaultPath);
                return device.EntropyId;
            }
            finally
            {
                CryptographicOperations.ZeroMemory(kSeal);
            }
        }
        catch
        {
            if (File.Exists(DeviceSealPath)) File.Delete(DeviceSealPath);
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(share);
            CryptographicOperations.ZeroMemory(entropy);
        }
    }

    /// v1 ↔ v2 份额迁移（三档切换条：系统保护 ↔ 口令保护）。
    /// 主密钥 K 不变 → 既有条目原样沿用不重加密；仅换授权份额 S：
    ///   target=os（v2 → v1）：新随机 S_os 写入 OS 安全存储，vault 重写 v1 布局
    ///   target=password（v1 → v2）：S_pw = Argon2id(口令)，vault 重写 v2 布局，删除 OS 份额
    /// 调用方须已解锁（持 master）；[password] 仅 v1 → v2 需要，用后由调用方清零。
    /// 失败回滚不残留半态（v2 → v1 先落 OS 存储、vault 写失败回滚删除；
    /// v1 → v2 写文件成功后删 OS 份额，删除失败残留份额无害——v2 解锁走口令分支）。
    /// 多封装（v3）不可经此切换：走 ClearDeviceSeal 回落口令模式。
    public void SwitchMode(ReadOnlySpan<byte> master, string target, byte[]? password)
    {
        if (!Initialized) throw new InvalidOperationException("vault 未初始化");
        var vault = VaultFile.Load(VaultPath);
        var mode = vault.Mode;
        if (mode == VaultMode.MultiSeal)
            throw new InvalidOperationException("多封装模式不可经 switch-mode 切换：请用「关闭设备绑定」回落口令模式");

        var newKeyVault = new byte[KeySplit.KeySize];
        try
        {
            if (target == "os")
            {
                if (mode != VaultMode.Password)
                    throw new InvalidOperationException($"当前为 {mode}，非口令模式，无需切换");
                var sOs = RandomNumberGenerator.GetBytes(KeySplit.KeySize);
                try
                {
                    for (var i = 0; i < KeySplit.KeySize; i++)
                        newKeyVault[i] = (byte)(master[i] ^ sOs[i]);
                    _store.Store(ShareKey, sOs);              // 先落 OS 安全存储
                    try
                    {
                        var v1 = VaultFile.Create(newKeyVault, _store.Backend);
                        v1.Entries.AddRange(vault.Entries);   // K 不变：条目原样沿用
                        v1.Save(VaultPath);
                    }
                    catch { _store.Delete(ShareKey); throw; } // vault 写失败回滚
                }
                finally { CryptographicOperations.ZeroMemory(sOs); }
            }
            else if (target == "password")
            {
                if (mode != VaultMode.OsStore)
                    throw new InvalidOperationException($"当前为 {mode}，非 OS 模式，无需切换");
                if (password == null)
                    throw new InvalidOperationException("切换到口令模式需要新口令");
                var salt = RandomNumberGenerator.GetBytes(VaultFile.SaltSize);
                var kdf = Argon2id.KdfParams.Default;
                var sPw = Argon2id.Derive(password, salt, [], [], kdf.MKiB, kdf.T, kdf.P, KeySplit.KeySize);
                try
                {
                    for (var i = 0; i < KeySplit.KeySize; i++)
                        newKeyVault[i] = (byte)(master[i] ^ sPw[i]);
                    var v2 = VaultFile.CreatePassword(newKeyVault, salt, kdf);
                    v2.Entries.AddRange(vault.Entries);       // K 不变：条目原样沿用
                    v2.Save(VaultPath);
                    try { _store.Delete(ShareKey); } catch { /* 残留份额无害 */ }
                }
                finally { CryptographicOperations.ZeroMemory(sPw); }
            }
            else
            {
                throw new ArgumentException($"未知切换目标: {target}");
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(newKeyVault);
        }
    }

    /// 重新绑定当前设备（换机/重装后口令恢复成功 → 用新指纹重密封熵）：
    /// 生成新熵 E' 写 device.seal（当前指纹），用 E' 重密封 S 替换 kind=2 封装；
    /// 口令封装（kind=1）不受影响。返回新熵标识（entropy_id）。
    public byte[] RebindDevice(ReadOnlySpan<byte> master, string? fingerprint)
    {
        var vault = VaultFile.Load(VaultPath);
        if (vault.Mode != VaultMode.MultiSeal)
            throw new InvalidOperationException("仅多封装模式（设备绑定）支持重新绑定");
        fingerprint ??= Fingerprint.Collect();
        if (fingerprint == null)
            throw new InvalidOperationException("无法采集设备指纹（设备熵路径不可用）");
        var share = RecoverShare(vault, master);
        var entropy = RandomNumberGenerator.GetBytes(DeviceEntropyFile.EntropySize);
        var device = DeviceEntropyFile.Create();
        var kSeal = DeviceEntropyFile.ShareSealKey(entropy);
        try
        {
            device.SealAndSave(DeviceSealPath, entropy, fingerprint);
            var newSeal = SealShareWithEntropy(share, kSeal, device.EntropyId);
            var idx = vault.Seals.FindIndex(s => s.Kind == SealKind.DeviceEntropy);
            if (idx >= 0) vault.Seals[idx] = newSeal;
            else vault.Seals.Add(newSeal);
            vault.Save(VaultPath);
            return device.EntropyId;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(kSeal);
            CryptographicOperations.ZeroMemory(entropy);
        }
    }

    /// 会话解锁后由 K 反解 S 份额（S = K_vault ⊕ K），用于重密封/重绑定。
    private static byte[] RecoverShare(VaultFile vault, ReadOnlySpan<byte> master)
    {
        var s = new byte[KeySplit.KeySize];
        for (var i = 0; i < KeySplit.KeySize; i++) s[i] = (byte)(vault.KeyVault[i] ^ master[i]);
        return s;
    }

    /// 存储凭据。**消费语义**：调用结束后 [plaintext] 数组被清零，调用方不得再持有明文。
    public void Set(string uid, byte[] plaintext)
    {
        EnsureInitialized();
        using var master = LockedBuffer.Alloc(KeySplit.KeySize);
        LoadMasterKeyInto(master.Span);
        try
        {
            var vault = VaultFile.Load(VaultPath);
            vault.Entries.RemoveAll(e => e.Uid == uid);
            vault.Entries.Add(vault.Encrypt(uid, plaintext, master.Span));
            vault.Save(VaultPath);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    /// 读取凭据明文（返回新数组；调用方用后必须 [CryptographicOperations.ZeroMemory]）。
    public byte[]? Get(string uid)
    {
        EnsureInitialized();
        using var master = LockedBuffer.Alloc(KeySplit.KeySize);
        LoadMasterKeyInto(master.Span);
        var vault = VaultFile.Load(VaultPath);
        var entry = vault.Entries.FirstOrDefault(e => e.Uid == uid);
        return entry == null ? null : vault.Decrypt(entry, master.Span);
    }

    public bool Delete(string uid)
    {
        EnsureInitialized();
        var vault = VaultFile.Load(VaultPath);
        var removed = vault.Entries.RemoveAll(e => e.Uid == uid) > 0;
        if (removed) vault.Save(VaultPath);
        return removed;
    }

    // ── 会话持钥路径（§3.8）：主密钥已由 serve 会话解锁持于 LockedBuffer，
    //    命令循环直接复用，避免每条命令重建（减少密钥在堆中出现的次数）──

    /// 读或建会话锚点：无 `__auth__` 条目（首次/旧版 vault）→ 生成 16B 随机 T
    /// 加密入库并返回；已有 → 解密回读。调用方负责向主进程交付 T 并妥善保存。
    public byte[] GetOrCreateAuthAnchor(ReadOnlySpan<byte> master)
    {
        var vault = VaultFile.Load(VaultPath);
        var entry = vault.Entries.FirstOrDefault(e => e.Uid == AuthUid);
        if (entry != null) return vault.Decrypt(entry, master);
        var t = RandomNumberGenerator.GetBytes(16);
        vault.Entries.Add(vault.Encrypt(AuthUid, t, master));
        vault.Save(VaultPath);
        return t;
    }

    /// 会话持钥读取（无条目返回 null；调用方须对返回明文 [CryptographicOperations.ZeroMemory]）。
    public byte[]? GetWith(string uid, ReadOnlySpan<byte> master)
    {
        var vault = VaultFile.Load(VaultPath);
        var entry = vault.Entries.FirstOrDefault(e => e.Uid == uid);
        return entry == null ? null : vault.Decrypt(entry, master);
    }

    /// 会话持钥写入（消费语义：调用结束后 [plaintext] 被清零）。
    public void SetWith(string uid, byte[] plaintext, ReadOnlySpan<byte> master)
    {
        var vault = VaultFile.Load(VaultPath);
        vault.Entries.RemoveAll(e => e.Uid == uid);
        vault.Entries.Add(vault.Encrypt(uid, plaintext, master));
        vault.Save(VaultPath);
        CryptographicOperations.ZeroMemory(plaintext);
    }

    /// 全量销毁：删除授权侧份额 + vault 文件 + 设备熵文件 + 锁定状态——
    /// 旧密文不可恢复（明文从未落盘）。
    public void Destroy()
    {
        _store.Delete(ShareKey);
        if (File.Exists(VaultPath)) File.Delete(VaultPath);
        if (File.Exists(DeviceSealPath)) File.Delete(DeviceSealPath);
        _lockout.Clear();
    }

    private void EnsureInitialized()
    {
        if (!Initialized) throw new InvalidOperationException("vault 未初始化，请先 init");
    }
}
