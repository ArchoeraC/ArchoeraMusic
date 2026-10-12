// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Security.Cryptography;

namespace Archoera.Vault;

/// 设备密钥路径解锁失败（`device.key` 缺失/损坏）——主进程应转「恢复码」流
/// （serve 应答 `err NEED_RECOVERY`；m2a 用恢复槽，m2b 无恢复则同样以该码暴露）。
/// 不是解锁失败：不计入锁定退避（设备密钥缺失是环境/恢复场景，非爆破尝试）。
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

/// vault 服务（命令语义）：init-crypto / init-file / init-m1 / init-m2a / init-m2b /
/// serve / destroy / status。
///
/// 支持两种容器：
///   - LEGACY 'C'（crypto 传统单因子）：主密钥 K 整体锚定于 OS 安全存储
///     （DPAPI/Keychain/libsecret）或文件密钥库（file）；vault 文件不含密钥材料。
///   - 'S'（slots）：K 由槽位表封装（口令 / 设备 / 恢复 / 口令+设备），条目以 K
///     直接加密并以尾部 HMAC 锚定。
/// 主密钥 K 永不落盘（file 后端与 slots 槽位密文除外），短时持有于
/// [LockedBuffer]（mlock + 用后 zeroize）。
public sealed class VaultService
{
    public const string VaultFileName = "credentials.vault";
    public const string ShareKey = "master-share";
    public const string DeviceKeyFileName = DeviceKeyFile.FileName;

    /// 会话锚点条目 uid（§3.8 握手）：vault 生成 16B 随机 T 经主密钥加密存此条目，
    /// 握手时解密回读交主进程保存——后续会话比对该值以确认「仍是同一把 K 的 vault」。
    public const string AuthUid = "__auth__";

    private readonly string _dataDir;
    private readonly ISecretStore _store;
    private readonly VaultLockout _lockout;

    public VaultService(string dataDir) : this(dataDir, null) { }

    /// [store] 注入用于显式选择后端（如文件密钥模式 init-file 直接给 FileStore；
    /// null → 工厂按 vault 文件头/env/平台自动分发）。'S'（slots）模式自包含
    /// （口令派生 KEK + 头部 HMAC），默认走 [NullSecretStore]——headless/无钥匙串
    /// 也能 status/serve，不改变其他模式的后端选择行为。
    public VaultService(string dataDir, ISecretStore? store)
    {
        _dataDir = dataDir;
        _store = store ?? SelectDefaultStore(dataDir);
        _lockout = new VaultLockout(_store, dataDir);
    }

    /// 无显式 [store] 时的默认后端：已存在的 'S' vault → [NullSecretStore]（自包含）；
    /// 其余（含未初始化）→ 既有工厂分发（file/dpapi/keychain/libsecret）。
    private static ISecretStore SelectDefaultStore(string dataDir)
    {
        var vaultPath = Path.Combine(dataDir, VaultFileName);
        if (File.Exists(vaultPath))
        {
            try
            {
                if (VaultFile.ReadHeader(vaultPath).Mode == VaultMode.Slots)
                    return new NullSecretStore();
            }
            catch
            {
                // 文件头损坏：交由默认工厂（后续加载时暴露为明确错误）
            }
        }
        return SecretStoreFactory.Create(dataDir);
    }

    /// 解锁失败退避（[VaultLockout]）——与份额槽位共用同一后端实例，退避状态内嵌于
    /// `master-share` 值（[security-review SEC-05]）。serve 会话复用本实例，避免第二份
    /// 状态视图导致读写不一致。
    internal VaultLockout Lockout => _lockout;

    public string VaultPath => Path.Combine(_dataDir, VaultFileName);

    /// 设备密钥路径（`<dataDir>/device.key`，F2 设备/口令+设备槽用，0600）。
    public string DeviceKeyPath => Path.Combine(_dataDir, DeviceKeyFileName);

    /// 当前份额后端（v4 指纹：file/dpapi/keychain/libsecret…）。
    /// status 命令据此暴露，供主进程区分「OS 安全存储 crypto」与
    /// 「文件密钥模式（file）」——两者模式同为 crypto 但安全性不同。
    public string Backend => _store.Backend;

    public bool Initialized => File.Exists(VaultPath);

    /// 份额锚定模式（读文件头判定；未初始化返回 [VaultMode.Crypto] 占位）。
    public VaultMode Mode => Initialized ? VaultFile.ReadHeader(VaultPath).Mode : VaultMode.Crypto;

    /// 'S'（slots）容器的因子模式（m1/m2a/m2b，由槽位集合推导；非 slots → None）。
    /// 仅读文件头（不加载/不解密任何凭据），供 status/serve 判定握手形态。
    public SlotsMode SlotsMode
    {
        get
        {
            if (!Initialized) return SlotsMode.None;
            var header = VaultFile.ReadHeader(VaultPath);
            return header.Mode == VaultMode.Slots
                ? VaultFile.DetectSlotsMode(header.SlotKinds ?? [])
                : SlotsMode.None;
        }
    }

    /// 当前口令承载槽（m1 口令 / m2a 口令+设备）的 Argon2id 强度参数（m/t/p）。
    /// 仅读文件头（不解密任何凭据）——供 status 展示当前档位；crypto / m2b / 未初始化
    /// 返回 null（无口令 KDF 可展示）。与 [ChangeKdf] 配合实现「可查看/可调强度」。
    public Argon2id.KdfParams? CurrentKdf
    {
        get
        {
            if (!Initialized) return null;
            return VaultFile.ReadHeader(VaultPath).Kdf;
        }
    }

    /// 初始化（LEGACY：crypto 传统单因子，推荐）：主密钥 K 整体存 OS 安全存储
    /// （DPAPI/Keychain/libsecret），vault 文件不含密钥材料（key_vault=32B 零占位）。
    /// 与 OS 模式（v1/v4，2-of-2 拆分）相比无份额配对、无口令、无设备熵，
    /// 稳定性更高（不存在份额丢失导致的凭据整体丢失）；安全性降为单点
    /// （OS 钥匙串被攻破 = 凭据全泄露）。
    /// 失败回滚（授权侧写入失败时不残留半初始化 vault）。
    public void InitCrypto() => InitCrypto(null);

    /// [master] 非 null 时以其为主密钥 K（不随机生成）——供 headless 经 **stdin** 注入
    /// （`init-file --key-stdin`，不使用 argv/env，见 security-review SEC-02）；
    /// 长度须为 [KeySplit.KeySize]；调用方负责清零传入缓冲。
    public void InitCrypto(byte[]? master)
    {
        if (Initialized) throw new InvalidOperationException("vault 已初始化，请先 destroy");
        if (master != null && master.Length != KeySplit.KeySize)
            throw new ArgumentException($"主密钥须为 {KeySplit.KeySize} 字节");
        _lockout.Clear();
        var generated = master == null;
        var k = master ?? RandomNumberGenerator.GetBytes(KeySplit.KeySize);
        try
        {
            _lockout.SetShare(k); // K 整体入 OS 安全存储 / 文件密钥库
            VaultFile.CreateCrypto(_store.Backend).Save(VaultPath);
        }
        catch
        {
            if (File.Exists(VaultPath)) File.Delete(VaultPath);
            throw;
        }
        finally
        {
            if (generated) CryptographicOperations.ZeroMemory(k);
        }
    }

    /// 初始化（'S' slots 容器，F1 = 仅口令槽）：生成随机主密钥 K，用
    /// KEK = Argon2id(password, salt, ad=vaultId‖kind) 包裹 K 写入槽位表；
    /// 条目直接以 K 加密，尾部写 HMAC-SHA256(K, header‖entries)。
    /// 口令绝不落盘/落 argv；salt 与 KDF 参数随槽位表存储。
    /// [kdfParams] 为用户可选强度（m/t/p，非密文，经 argv 传入）；null → 默认档
    /// （[Argon2id.KdfParams.Default]）。越界经 [VaultLimits.ValidateKdf] 快速拒绝。
    /// [password] 用后由调用方清零（本方法仅读取）。
    public void InitSlots(byte[] password, byte[]? salt = null,
        Argon2id.KdfParams? kdfParams = null)
    {
        if (Initialized) throw new InvalidOperationException("vault 已初始化，请先 destroy");
        _lockout.Clear();
        salt ??= RandomNumberGenerator.GetBytes(VaultFile.SaltSize);
        var kdf = kdfParams ?? Argon2id.KdfParams.Default;
        VaultLimits.ValidateKdf(kdf.MKiB, kdf.T, kdf.P);
        var vaultId = RandomNumberGenerator.GetBytes(VaultFile.VaultIdSize);
        var createdAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var master = RandomNumberGenerator.GetBytes(KeySplit.KeySize);
        var ad = VaultFile.BuildSlotAd(vaultId, SlotKind.Password);
        var kek = Argon2id.Derive(password, salt, [], ad, kdf.MKiB, kdf.T, kdf.P, KeySplit.KeySize);
        try
        {
            var nonce = RandomNumberGenerator.GetBytes(VaultFile.NonceSize);
            var wrapped = new byte[KeySplit.KeySize + VaultFile.TagSize];
            using (var gcm = new AesGcm(kek, VaultFile.TagSize))
            {
                gcm.Encrypt(nonce, master, wrapped.AsSpan(0, KeySplit.KeySize),
                    wrapped.AsSpan(KeySplit.KeySize), ad);
            }
            var slot = new VaultSlot
            {
                Kind = SlotKind.Password,
                Kdf = kdf,
                Salt = salt,
                Nonce = nonce,
                Wrapped = wrapped,
            };
            VaultFile.CreateSlots(vaultId, createdAt, VaultFile.AlgAes256Gcm,
                new[] { slot }).Save(VaultPath, master);
        }
        catch
        {
            if (File.Exists(VaultPath)) File.Delete(VaultPath);
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(kek);
            CryptographicOperations.ZeroMemory(master);
        }
    }

    /// 初始化（'S' slots，m2a = 口令+设备双因子 + 恢复槽）：生成 K、
    /// deviceSecret（写 device.key）与 32B 恢复码；两个槽位均封装同一 K：
    ///   - kind=4（PasswordDevice）：KEK = HKDF(Argon2id(口令, salt, ad) ‖ deviceSecret)；
    ///   - kind=3（Recovery）：KEK = HKDF(recoveryCodeBytes, salt, "…recovery")。
    /// 解锁需「口令 + device.key」，device.key 丢失时用恢复码兜底。
    /// [kdfParams] 为口令+设备槽的用户可选强度（非密文，经 argv）；null → 默认档。
    /// [password] 用后由调用方清零（本方法仅读取）；返回恢复码展示串（仅此一次可展示）。
    public string InitM2a(byte[] password, byte[]? salt = null,
        Argon2id.KdfParams? kdfParams = null)
    {
        if (Initialized) throw new InvalidOperationException("vault 已初始化，请先 destroy");
        _lockout.Clear();
        salt ??= RandomNumberGenerator.GetBytes(VaultFile.SaltSize);
        var kdf = kdfParams ?? Argon2id.KdfParams.Default;
        VaultLimits.ValidateKdf(kdf.MKiB, kdf.T, kdf.P);
        var vaultId = RandomNumberGenerator.GetBytes(VaultFile.VaultIdSize);
        var createdAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var master = RandomNumberGenerator.GetBytes(KeySplit.KeySize);
        var deviceSecret = DeviceKeyFile.CreateAndSave(_dataDir);
        var recoveryBytes = RandomNumberGenerator.GetBytes(RecoveryCode.ByteSize);
        var recoveryCode = RecoveryCode.Encode(recoveryBytes);
        byte[]? baseKek = null;
        byte[]? pdKek = null;
        byte[]? recKek = null;
        try
        {
            // kind=4：口令+设备双因子槽（Argon2id 参数随槽存储）
            var pdAd = VaultFile.BuildSlotAd(vaultId, SlotKind.PasswordDevice);
            baseKek = SlotCrypto.DerivePassword(password, salt, pdAd, kdf);
            pdKek = SlotCrypto.DerivePasswordDevice(baseKek, deviceSecret, salt);
            var pdSlot = WrapSlot(SlotKind.PasswordDevice, kdf, salt, pdKek, master, pdAd);

            // kind=3：恢复槽（独立 salt；KDF 参数占位不使用）
            var recSalt = RandomNumberGenerator.GetBytes(VaultFile.SaltSize);
            var recAd = VaultFile.BuildSlotAd(vaultId, SlotKind.Recovery);
            recKek = SlotCrypto.DeriveRecovery(recoveryBytes, recSalt);
            var recSlot = WrapSlot(SlotKind.Recovery, null, recSalt, recKek, master, recAd);

            VaultFile.CreateSlots(vaultId, createdAt, VaultFile.AlgAes256Gcm,
                new[] { pdSlot, recSlot }).Save(VaultPath, master);
        }
        catch
        {
            if (File.Exists(VaultPath)) File.Delete(VaultPath);
            DeviceKeyFile.Delete(_dataDir);
            throw;
        }
        finally
        {
            if (baseKek != null) CryptographicOperations.ZeroMemory(baseKek);
            if (pdKek != null) CryptographicOperations.ZeroMemory(pdKek);
            if (recKek != null) CryptographicOperations.ZeroMemory(recKek);
            CryptographicOperations.ZeroMemory(deviceSecret);
            CryptographicOperations.ZeroMemory(recoveryBytes);
            CryptographicOperations.ZeroMemory(master);
        }
        return recoveryCode;
    }

    /// 初始化（'S' slots，m2b = 仅设备槽）：生成 K 与 deviceSecret（写 device.key），
    /// kind=2（Device）封装 K——本机免密解锁（无口令、无恢复槽）。
    /// KEK = HKDF-SHA256(deviceSecret, slotSalt, "archoera.slot.device")。
    public void InitM2b()
    {
        if (Initialized) throw new InvalidOperationException("vault 已初始化，请先 destroy");
        _lockout.Clear();
        var vaultId = RandomNumberGenerator.GetBytes(VaultFile.VaultIdSize);
        var createdAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var master = RandomNumberGenerator.GetBytes(KeySplit.KeySize);
        var deviceSecret = DeviceKeyFile.CreateAndSave(_dataDir);
        var salt = RandomNumberGenerator.GetBytes(VaultFile.SaltSize);
        var ad = VaultFile.BuildSlotAd(vaultId, SlotKind.Device);
        var kek = SlotCrypto.DeriveDevice(deviceSecret, salt);
        try
        {
            var slot = WrapSlot(SlotKind.Device, null, salt, kek, master, ad);
            VaultFile.CreateSlots(vaultId, createdAt, VaultFile.AlgAes256Gcm,
                new[] { slot }).Save(VaultPath, master);
        }
        catch
        {
            if (File.Exists(VaultPath)) File.Delete(VaultPath);
            DeviceKeyFile.Delete(_dataDir);
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(kek);
            CryptographicOperations.ZeroMemory(deviceSecret);
            CryptographicOperations.ZeroMemory(master);
        }
    }

    /// 用 [kek] 封装主密钥 [master] 为槽位（AES-256-GCM，ad=vaultId‖kind）。
    /// [kdf] 为 null（设备/恢复槽）时写占位 (0,0,0)。
    private static VaultSlot WrapSlot(
        SlotKind kind, Argon2id.KdfParams? kdf, byte[] salt, byte[] kek,
        byte[] master, byte[] ad)
    {
        var nonce = RandomNumberGenerator.GetBytes(VaultFile.NonceSize);
        var wrapped = new byte[KeySplit.KeySize + VaultFile.TagSize];
        using (var gcm = new AesGcm(kek, VaultFile.TagSize))
        {
            gcm.Encrypt(nonce, master, wrapped.AsSpan(0, KeySplit.KeySize),
                wrapped.AsSpan(KeySplit.KeySize), ad);
        }
        return new VaultSlot
        {
            Kind = kind,
            Kdf = kdf ?? new Argon2id.KdfParams(0, 0, 0),
            Salt = salt,
            Nonce = nonce,
            Wrapped = wrapped,
        };
    }

    /// **重键 KDF（用户可选强度，不丢数据）**：用**当前口令**以**旧参数**解出口令承载槽
    /// 封装的同一主密钥 K，再用**新参数**（新随机 salt + 新 nonce）重新封装回原槽——
    /// K、条目密文与 `__auth__` 锚点均不变，仅口令槽的 `m/t/p/salt/nonce/wrapped` 更新，
    /// 尾部 HMAC 以同一 K 重算后原子保存（保留 `.bak`）。
    /// 边界（务必理解）：
    ///   - **必须提供口令**：旧 KEK 只能由旧口令 + 旧参数派生；口令错误 / 槽被篡改在
    ///     AES-GCM 认证处 fail-closed（抛 [AuthenticationTagMismatchException]）；
    ///   - 仅 'S' 口令类槽支持：crypto（K 整体存 OS 存储，无口令 KDF）与 m2b（无口令槽）
    ///     抛 [InvalidOperationException]；m2a 仅重键口令+设备槽，恢复槽（HKDF，无 Argon2id）
    ///     **原样保留**；
    ///   - m2a 需 `device.key`：缺失抛 [NeedRecoveryException]（环境缺失，非爆破），
    ///     调用方应转恢复码流（本方法不修改恢复槽，故恢复码仍可用）。
    /// [password] 由调用方所有（本方法仅读取，不负责清零）；[kdf] 越界经
    /// [VaultLimits.ValidateKdf] 拒绝。
    public void ChangeKdf(byte[] password, Argon2id.KdfParams kdf)
    {
        EnsureInitialized();
        VaultLimits.ValidateKdf(kdf.MKiB, kdf.T, kdf.P);
        var vault = VaultFile.Load(VaultPath);
        if (vault.Mode != VaultMode.Slots || vault.VaultId == null
            || vault.MacInput == null || vault.Trailer == null)
        {
            // crypto / file（无口令 KDF 可重键）——明确拒绝，不改动任何字节
            throw new InvalidOperationException("该模式不支持更改 KDF");
        }
        var slotMode = VaultFile.DetectSlotsMode(vault.Slots.Select(s => s.Kind).ToList());
        var targetKind = slotMode switch
        {
            SlotsMode.M1 => SlotKind.Password,
            SlotsMode.M2a => SlotKind.PasswordDevice,
            _ => throw new InvalidOperationException("该模式不支持更改 KDF"),
        };
        var index = vault.Slots.FindIndex(s => s.Kind == targetKind);
        if (index < 0) throw new InvalidOperationException("vault 缺少口令槽位，无法更改 KDF");
        var slot = vault.Slots[index];
        var ad = VaultFile.BuildSlotAd(vault.VaultId, slot.Kind);
        var newSalt = RandomNumberGenerator.GetBytes(VaultFile.SaltSize);
        var newNonce = RandomNumberGenerator.GetBytes(VaultFile.NonceSize);
        var k = new byte[KeySplit.KeySize];
        byte[]? deviceSecret = null;
        byte[]? oldBaseKek = null;
        byte[]? oldKek = null;
        byte[]? newBaseKek = null;
        byte[]? newKek = null;
        try
        {
            // m2a：口令+设备槽需本机设备因子（缺失 → NeedRecoveryException）
            if (slot.Kind == SlotKind.PasswordDevice)
                deviceSecret = DeviceKeyFile.Load(_dataDir);

            // 1) 旧参数 + 口令 → 旧 KEK → 解出 K（口令错误 → GCM 认证失败）
            oldBaseKek = SlotCrypto.DerivePassword(password, slot.Salt, ad, slot.Kdf);
            oldKek = slot.Kind == SlotKind.PasswordDevice
                ? SlotCrypto.DerivePasswordDevice(oldBaseKek, deviceSecret!, slot.Salt)
                : oldBaseKek;
            using (var gcm = new AesGcm(oldKek, VaultFile.TagSize))
            {
                gcm.Decrypt(slot.Nonce, slot.Wrapped.AsSpan(0, KeySplit.KeySize),
                    slot.Wrapped.AsSpan(KeySplit.KeySize), k, ad);
            }
            // 尾部 HMAC 复核（纵深防御；K 未变，Save 会以同一 K 重算）
            if (!CryptographicOperations.FixedTimeEquals(
                    VaultFile.ComputeSlotsMac(k, vault.MacInput), vault.Trailer))
            {
                throw new AuthenticationTagMismatchException(
                    "slots vault 尾部 HMAC 校验失败（header/条目被篡改）");
            }

            // 2) 新参数 + 口令 → 新 KEK → 用新 salt/nonce 重新封装同一 K
            newBaseKek = SlotCrypto.DerivePassword(password, newSalt, ad, kdf);
            newKek = slot.Kind == SlotKind.PasswordDevice
                ? SlotCrypto.DerivePasswordDevice(newBaseKek, deviceSecret!, newSalt)
                : newBaseKek;
            var wrapped = new byte[KeySplit.KeySize + VaultFile.TagSize];
            using (var gcm = new AesGcm(newKek, VaultFile.TagSize))
            {
                gcm.Encrypt(newNonce, k, wrapped.AsSpan(0, KeySplit.KeySize),
                    wrapped.AsSpan(KeySplit.KeySize), ad);
            }

            // 3) 仅替换该槽（其余槽/条目/锚点原样）；以同一 K 重算尾部 HMAC 后原子保存
            vault.Slots[index] = new VaultSlot
            {
                Kind = slot.Kind,
                Kdf = kdf,
                Salt = newSalt,
                Nonce = newNonce,
                Wrapped = wrapped,
            };
            vault.Save(VaultPath, k);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(k);
            if (deviceSecret != null) CryptographicOperations.ZeroMemory(deviceSecret);
            if (oldBaseKek != null) CryptographicOperations.ZeroMemory(oldBaseKek);
            if (oldKek != null && !ReferenceEquals(oldKek, oldBaseKek))
                CryptographicOperations.ZeroMemory(oldKek);
            if (newBaseKek != null) CryptographicOperations.ZeroMemory(newBaseKek);
            if (newKek != null && !ReferenceEquals(newKek, newBaseKek))
                CryptographicOperations.ZeroMemory(newKek);
        }
    }

    /// 协同重建主密钥到调用方缓冲（须为 [LockedBuffer] 的 mlock 区，用后自动清零）。
    /// 'S'（slots）：[secret] 为因子材料（口令字节 / 恢复码 UTF-8），
    /// [slotLabel] 为可选槽位标签（`"rec"` = 恢复槽；null = 默认因子路径）；
    /// 设备路径读 `<dataDir>/device.key`，缺失抛 [NeedRecoveryException]。
    /// LEGACY 'C'（crypto）：[secret]/[slotLabel] 忽略，K 整体从存储后端取回。
    /// 授权侧份额（S）读入普通堆后立即清零；重建结果落于锁定内存，不进可换页堆。
    public void LoadMasterKeyInto(Span<byte> dest, byte[]? secret = null, string? slotLabel = null)
    {
        var vault = VaultFile.Load(VaultPath);
        if (vault.Mode == VaultMode.Slots)
        {
            // 'S'（slots）：按槽位集合判定因子模式（m1/m2a/m2b），选取槽位并派生
            // KEK 解出 K；随后**立即**校验尾部 HMAC（verify-before-decrypt）后再交付。
            // 无份额重组合；设备路径缺 device.key → NeedRecoveryException（环境缺失）。
            if (vault.VaultId == null || vault.MacInput == null || vault.Trailer == null)
                throw new InvalidDataException("slots vault 头部不完整（缺 vaultId/HMAC），拒绝加载");
            var slotMode = VaultFile.DetectSlotsMode(vault.Slots.Select(s => s.Kind).ToList());
            var (slot, kek) = SelectSlotAndKek(vault, slotMode, secret, slotLabel);
            try
            {
                var ad = VaultFile.BuildSlotAd(vault.VaultId, slot.Kind);
                var k = new byte[KeySplit.KeySize];
                try
                {
                    using (var gcm = new AesGcm(kek, VaultFile.TagSize))
                    {
                        // 因子错误 / 槽位被篡改 → GCM 认证失败（AuthenticationTagMismatchException）
                        gcm.Decrypt(slot.Nonce, slot.Wrapped.AsSpan(0, KeySplit.KeySize),
                            slot.Wrapped.AsSpan(KeySplit.KeySize), k, ad);
                    }
                    var mac = VaultFile.ComputeSlotsMac(k, vault.MacInput);
                    if (!CryptographicOperations.FixedTimeEquals(mac, vault.Trailer))
                    {
                        throw new AuthenticationTagMismatchException(
                            "slots vault 尾部 HMAC 校验失败（header/条目被篡改）");
                    }
                    k.CopyTo(dest);
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(k);
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(kek);
            }
            return;
        }
        // LEGACY（crypto 传统单因子）：K 整体存 OS 安全存储 / 文件密钥库，无份额配对——
        // 后端指纹照常校验（防不同存储后端混用数据目录），取回即主密钥。
        if (vault.Mode == VaultMode.Crypto)
        {
            if (vault.Backend != null && vault.Backend != _store.Backend)
            {
                throw new VaultShareBackendMismatchException(vault.Backend, _store.Backend);
            }
            var kCrypto = _lockout.GetShare()
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
        throw new InvalidDataException("不支持的 vault 模式，拒绝加载");
    }

    /// 便捷重载（crypto 免密路径）。
    public void LoadMasterKeyInto(Span<byte> dest) => LoadMasterKeyInto(dest, null, null);

    /// 按因子模式选取槽位并派生 KEK（返回的 KEK 由调用方用后清零）。
    /// [secret] 语义随路径：口令字节 / 恢复码 UTF-8。设备因子缺失抛
    /// [NeedRecoveryException]（m2a 改用恢复码；m2b 无恢复则同样以该码暴露）。
    private (VaultSlot slot, byte[] kek) SelectSlotAndKek(
        VaultFile vault, SlotsMode slotMode, byte[]? secret, string? label)
    {
        switch (slotMode)
        {
            case SlotsMode.M1:
            {
                if (label != null)
                    throw new InvalidOperationException("m1：不接受槽位标签");
                if (secret == null)
                    throw new InvalidOperationException("slots 模式：解锁需要口令（握手第 4 字段）");
                var slot = vault.Slots.FirstOrDefault(s => s.Kind == SlotKind.Password)
                    ?? throw new InvalidOperationException("vault 无口令槽位，无法解锁");
                var ad = VaultFile.BuildSlotAd(vault.VaultId!, slot.Kind);
                return (slot, SlotCrypto.DerivePassword(secret, slot.Salt, ad, slot.Kdf));
            }
            case SlotsMode.M2a:
            {
                if (label == "rec")
                {
                    if (secret == null)
                        throw new InvalidOperationException("m2a 恢复路径：需要恢复码（握手第 4 字段）");
                    var slot = vault.Slots.FirstOrDefault(s => s.Kind == SlotKind.Recovery)
                        ?? throw new InvalidOperationException("vault 无恢复槽位，无法用恢复码解锁");
                    var codeBytes = RecoveryCode.DecodeUtf8(secret);
                    try { return (slot, SlotCrypto.DeriveRecovery(codeBytes, slot.Salt)); }
                    finally { CryptographicOperations.ZeroMemory(codeBytes); }
                }
                if (label != null)
                    throw new InvalidOperationException($"m2a：未知槽位标签 [{label}]");
                if (secret == null)
                    throw new InvalidOperationException("m2a：解锁需要口令（握手第 4 字段）");
                var pdSlot = vault.Slots.FirstOrDefault(s => s.Kind == SlotKind.PasswordDevice)
                    ?? throw new InvalidOperationException("vault 无口令+设备槽位，无法解锁");
                // 设备因子缺失 → NeedRecoveryException（改用恢复码；非爆破向量）
                var deviceSecret = DeviceKeyFile.Load(_dataDir);
                byte[]? baseKek = null;
                try
                {
                    var ad = VaultFile.BuildSlotAd(vault.VaultId!, pdSlot.Kind);
                    baseKek = SlotCrypto.DerivePassword(secret, pdSlot.Salt, ad, pdSlot.Kdf);
                    return (pdSlot,
                        SlotCrypto.DerivePasswordDevice(baseKek, deviceSecret, pdSlot.Salt));
                }
                finally
                {
                    if (baseKek != null) CryptographicOperations.ZeroMemory(baseKek);
                    CryptographicOperations.ZeroMemory(deviceSecret);
                }
            }
            case SlotsMode.M2b:
            {
                if (label != null)
                    throw new InvalidOperationException("m2b：不接受槽位标签（握手仅 3 字段）");
                var slot = vault.Slots.FirstOrDefault(s => s.Kind == SlotKind.Device)
                    ?? throw new InvalidOperationException("vault 无设备槽位，无法解锁");
                var deviceSecret = DeviceKeyFile.Load(_dataDir);
                try { return (slot, SlotCrypto.DeriveDevice(deviceSecret, slot.Salt)); }
                finally { CryptographicOperations.ZeroMemory(deviceSecret); }
            }
            default:
                throw new InvalidDataException("slots vault 槽位集合无法识别（无可用因子），拒绝加载");
        }
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
            vault.Save(VaultPath, master.Span);
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

    /// 会话持钥删除：与 [Delete] 相同，但可向 'S'（slots）模式提供主密钥 K 以重算
    /// 尾部 HMAC（会话已解锁持 K）。其余模式行为与 [Delete] 完全一致。
    public bool DeleteWith(string uid, ReadOnlySpan<byte> master)
    {
        EnsureInitialized();
        var vault = VaultFile.Load(VaultPath);
        var removed = vault.Entries.RemoveAll(e => e.Uid == uid) > 0;
        if (removed) vault.Save(VaultPath, master);
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
        vault.Save(VaultPath, master);
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
        vault.Save(VaultPath, master);
        CryptographicOperations.ZeroMemory(plaintext);
    }

    /// 全量销毁：删除授权侧份额 + vault 文件（含 `.bak` 备份）+ 设备密钥
    /// （`device.key`，F2）+ 锁定状态——旧密文不可恢复（明文从未落盘）。
    /// `.bak`/`device.key` 必须一并删除，否则"重置"后会残留可解副本。
    public void Destroy()
    {
        _lockout.DeleteShare();
        if (File.Exists(VaultPath)) File.Delete(VaultPath);
        var bak = VaultPath + ".bak";
        if (File.Exists(bak)) File.Delete(bak);
        DeviceKeyFile.Delete(_dataDir);
        _lockout.Clear();
    }

    private void EnsureInitialized()
    {
        if (!Initialized) throw new InvalidOperationException("vault 未初始化，请先初始化");
    }
}
