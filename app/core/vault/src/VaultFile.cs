using System.Security.Cryptography;
using System.Text;

namespace Archoera.Vault;

/// vault 文件格式：
/// ```
/// OS 模式（v1，向后兼容）：
///   magic "AVLT"(4B) | version(1B)=1 | reserved(3B) | key_vault(32B, K_vault = K ⊕ S)
///   然后 entry_count(u32) | entries…
/// OS 模式（v4，新增后端指纹，防构建形态混用数据目录）：
///   magic "AVLT"(4B) | version(1B)=4 | reserved(3B) | key_vault(32B, K_vault = K ⊕ S)
///   | backend_len(1B) | backend(utf8)                ← 份额存储后端指纹（如 "libsecret"）
///   然后 entry_count(u32) | entries…
/// 口令模式（v2）：
///   magic "AVLT"(4B) | version(1B)=2 | kdf(1B)=1 | reserved(2B)
///   | salt(16B) | m(u32) | t(u32) | p(u32)          ← Argon2id KDF 参数
///   | key_vault(32B, K_vault = K ⊕ S) | entry_count(u32) | entries…
/// entry: uid_len(1B) | uid(utf8) | salt(16B) | nonce(12B) | ct_len(u32) | ciphertext(ct|tag)
/// ```
/// v4 只在 v1 布局头部追加 backend 指纹字段（写入时 S 份额所落的后端标识）。
/// 解锁时若文件头指纹 ≠ 当前实际后端（如 PROD=libsecret 与 TEST=insecure 混用
/// 同一数据目录）→ 抛 [VaultShareBackendMismatchException]，把此前模糊的
/// GCM mismatch 升级为明确错误码；v1/v2/v3 旧文件无指纹字段（Backend=null），
/// 解锁时跳过校验，保持向后兼容。
/// 每条目独立 salt/nonce，AES-256-GCM（tag 16B 附于密文尾）。
/// 磁盘上仅存密文与 K_vault 份额；主密钥 K 由 [KeySplit] 2-of-2 重建，永不落盘。
/// 口令模式下 S 份额由 Argon2id 口令派生（[VaultService.InitPassword]），
/// KDF 参数随文件头存储（口令本身从不落盘）。
/// v3 多封装（[SealKind]）：S 分别被「设备熵」与「口令」密封，任一方解出即可
/// 协同重建 K（BitLocker 式：本机免密 + 设备变更走口令恢复，device-bound-vault-plan）。
public enum VaultMode
{
    /// 默认：S 份额存 OS 安全存储（DPAPI/Keychain/libsecret）。
    OsStore = 0,

    /// 可选高级：S 份额由用户口令经 Argon2id 派生（防 GPU 爆破）。
    Password = 1,

    /// v3：S 份额多封装（设备熵 + 可选口令恢复），本机免密、设备变更走恢复。
    MultiSeal = 2,
}

/// S 份额的封装类型（v3，device-bound-vault-plan §4.1）。
public enum SealKind : byte
{
    /// 口令封装：key = Argon2id(口令)，KDF 参数随封装块存储。
    Password = 1,

    /// 设备熵封装：key = HKDF-SHA256(设备熵 E, "archoera.share-seal")，
    /// 熵本体 E 存 device.seal（指纹密封），本封装只存 S 的密文与 entropy_id。
    DeviceEntropy = 2,
}

/// 加载上限（防恶意构造的 vault 文件 DoS，credential-vault-plan §8）：
/// 正常库仅 KB 级（每条目 ≤1KB，万条也 <10MB）——16MB/10 万条目/单条目 4MB
/// 留足余量；超限文件视为攻击（[VaultFile.Load] 快速拒绝，不分配/不循环）。
public static class VaultLimits
{
    public const long MaxFileSize = 16 * 1024 * 1024;
    public const uint MaxEntries = 100_000;
    public const int MaxEntryBytes = 4 * 1024 * 1024;
}

/// v3 多封装块：S 份额的单个密封（任一方解出 → K = K_vault ⊕ S）。
public sealed class VaultSeal
{
    public required SealKind Kind { get; init; }

    /// 口令封装：Argon2id 盐（16B）。
    public byte[]? Salt { get; init; }

    /// 口令封装：KDF 参数。
    public Argon2id.KdfParams? Kdf { get; init; }

    /// 设备熵封装：指向 device.seal 的熵标识（32B）。
    public byte[]? EntropyId { get; init; }

    public required byte[] Nonce { get; init; }
    public required byte[] Ciphertext { get; init; } // ct|tag（S 的密文）
}

/// 文件头元数据（非密文，供 serve 握手前读取模式/参数）。
/// v3 返回 [SealKinds]（只读 kind 列表，不加载密文）——serve 据此判定
/// 是否有口令封装可走恢复（NEED_RECOVERY）。
/// [Backend]：v4 OS 模式文件记录的份额后端指纹（v1/v2/v3 为 null，不校验）。
public sealed record VaultHeader(
    VaultMode Mode,
    byte[]? Salt,
    Argon2id.KdfParams? Kdf,
    IReadOnlyList<SealKind>? SealKinds = null,
    string? Backend = null);

public sealed class VaultFile
{
    public const uint Magic = 0x544C5641; // "AVLT"（小端）
    public const byte Version = 1;        // OS 模式（v1 布局）
    public const byte VersionPassword = 2; // 口令模式（v2 布局）
    public const byte VersionMultiSeal = 3; // 多封装（v3 布局，BitLocker 式）
    public const byte Version4 = 4;       // OS 模式 + 份额后端指纹（防构建形态混用）
    public const int SaltSize = 16;
    public const int NonceSize = 12;
    public const int TagSize = 16;

    /// 头部 K_vault 份额（32B，明文写盘——单独无法解密，见 [KeySplit]）。
    public required byte[] KeyVault { get; init; }

    /// 份额锚定方式（OS 安全存储 / 口令派生 / 多封装）。
    public VaultMode Mode { get; init; } = VaultMode.OsStore;

    /// v4 OS 模式记录的后端指纹（null = v1/v2/v3 旧文件无指纹，解锁不校验）。
    /// 由 [VaultService.Init]/[SwitchMode] 写入当前 [ISecretStore.Backend]。
    public string? Backend { get; init; }

    /// 口令模式的 Argon2id 盐（OS 模式为 null）。
    public byte[]? Salt { get; init; }

    /// 口令模式的 KDF 参数（OS 模式为 null）。
    public Argon2id.KdfParams? Kdf { get; init; }

    /// v3 多封装块（S 份额的密封列表；v1/v2 为空）。
    public List<VaultSeal> Seals { get; } = new();

    public List<VaultEntry> Entries { get; } = new();

    public sealed class VaultEntry
    {
        public required string Uid { get; init; }
        public required byte[] Salt { get; init; }
        public required byte[] Nonce { get; init; }
        public required byte[] Ciphertext { get; init; }
    }

    /// OS 模式工厂：K_vault 份额 + 可选后端指纹（非 null → 写 v4 布局并记录）。
    public static VaultFile Create(byte[] keyVault, string? backend = null)
        => new() { KeyVault = keyVault, Backend = backend };

    /// 口令模式工厂：K_vault 份额 + KDF 盐/参数随文件头存储。
    public static VaultFile CreatePassword(byte[] keyVault, byte[] salt, Argon2id.KdfParams kdf)
        => new() { KeyVault = keyVault, Mode = VaultMode.Password, Salt = salt, Kdf = kdf };

    /// 多封装工厂：K_vault 份额 + S 份额的密封列表（口令/设备熵，任一方可解）。
    public static VaultFile CreateMultiSeal(byte[] keyVault, IReadOnlyList<VaultSeal> seals)
    {
        var f = new VaultFile { KeyVault = keyVault, Mode = VaultMode.MultiSeal };
        f.Seals.AddRange(seals);
        return f;
    }

    /// 仅读文件头（magic/version/kdf 块）——serve 握手前判定模式用，
    /// 不加载/解密任何凭据（§3.8 握手前置：构造只触盘读文件头）。
    /// v3 额外返回 [SealKinds]（只读 kind 列表，不读密文）。
    public static VaultHeader ReadHeader(string path)
    {
        using var fs = File.OpenRead(path);
        using var br = new BinaryReader(fs);
        if (br.ReadUInt32() != Magic) throw new InvalidDataException("vault 文件头损坏（magic 不符）");
        var version = br.ReadByte();
        if (version == Version || version == Version4)
        {
            br.ReadBytes(3); // reserved（v1/v4：kdf 位恒 0 = OS 模式）
            var backend = version == Version4 ? ReadBackend(br) : null;
            return new VaultHeader(VaultMode.OsStore, null, null, null, backend);
        }
        if (version == VersionPassword)
        {
            var kdf = br.ReadByte();
            br.ReadBytes(2);
            if (kdf == 1)
            {
                var salt = br.ReadBytes(SaltSize);
                var m = br.ReadUInt32();
                var t = br.ReadUInt32();
                var p = br.ReadUInt32();
                return new VaultHeader(VaultMode.Password, salt,
                    new Argon2id.KdfParams((int)m, (int)t, (int)p));
            }
            return new VaultHeader(VaultMode.OsStore, null, null);
        }
        if (version == VersionMultiSeal)
        {
            br.ReadBytes(3); // flags(1B) + reserved(2B)
            br.ReadBytes(KeySplit.KeySize); // 跳过 K_vault（非密文，不加载凭据）
            var kinds = new List<SealKind>();
            var sealCount = br.ReadByte();
            for (var i = 0; i < sealCount; i++)
            {
                kinds.Add(ReadSeal(br).Kind);
            }
            return new VaultHeader(VaultMode.MultiSeal, null, null, kinds);
        }
        throw new InvalidDataException("vault 版本不兼容");
    }

    /// 读 v4 后端指纹（1B 长度 + UTF8；长度 0 视为无指纹）。
    private static string? ReadBackend(BinaryReader br)
    {
        var len = br.ReadByte();
        return len == 0 ? null : Encoding.UTF8.GetString(br.ReadBytes(len));
    }

    /// 读单个封装块（kind + 参数 + 密文）。
    private static VaultSeal ReadSeal(BinaryReader br)
    {
        var kind = (SealKind)br.ReadByte();
        return kind switch
        {
            SealKind.Password => new VaultSeal
            {
                Kind = kind,
                Salt = br.ReadBytes(SaltSize),
                Kdf = new Argon2id.KdfParams((int)br.ReadUInt32(), (int)br.ReadUInt32(), (int)br.ReadUInt32()),
                Nonce = br.ReadBytes(NonceSize),
                Ciphertext = br.ReadBytes((int)br.ReadUInt32()),
            },
            SealKind.DeviceEntropy => new VaultSeal
            {
                Kind = kind,
                EntropyId = br.ReadBytes(DeviceEntropyFile.EntropyIdSize),
                Nonce = br.ReadBytes(NonceSize),
                Ciphertext = br.ReadBytes((int)br.ReadUInt32()),
            },
            _ => throw new InvalidDataException($"未知封装类型 {(byte)kind}"),
        };
    }

    /// 写单个封装块。
    private static void WriteSeal(BinaryWriter bw, VaultSeal seal)
    {
        bw.Write((byte)seal.Kind);
        switch (seal.Kind)
        {
            case SealKind.Password:
                bw.Write(seal.Salt!);
                bw.Write((uint)seal.Kdf!.MKiB);
                bw.Write((uint)seal.Kdf.T);
                bw.Write((uint)seal.Kdf.P);
                break;
            case SealKind.DeviceEntropy:
                bw.Write(seal.EntropyId!);
                break;
            default:
                throw new InvalidDataException($"未知封装类型 {(byte)seal.Kind}");
        }
        bw.Write(seal.Nonce);
        bw.Write((uint)seal.Ciphertext.Length);
        bw.Write(seal.Ciphertext);
    }

    public static VaultFile Load(string path)
    {
        using var fs = File.OpenRead(path);
        using var br = new BinaryReader(fs);
        if (fs.Length > VaultLimits.MaxFileSize)
            throw new InvalidDataException("vault 文件过大（可能被恶意填充），拒绝加载");
        if (br.ReadUInt32() != Magic) throw new InvalidDataException("vault 文件头损坏（magic 不符）");
        var version = br.ReadByte();
        VaultFile file;
        if (version == Version || version == Version4)
        {
            br.ReadBytes(3);
            file = new VaultFile
            {
                KeyVault = br.ReadBytes(KeySplit.KeySize),
                Backend = version == Version4 ? ReadBackend(br) : null,
            };
        }
        else if (version == VersionPassword)
        {
            var kdf = br.ReadByte();
            br.ReadBytes(2);
            if (kdf == 1)
            {
                var salt = br.ReadBytes(SaltSize);
                var m = br.ReadUInt32();
                var t = br.ReadUInt32();
                var p = br.ReadUInt32();
                file = new VaultFile
                {
                    KeyVault = br.ReadBytes(KeySplit.KeySize),
                    Mode = VaultMode.Password,
                    Salt = salt,
                    Kdf = new Argon2id.KdfParams((int)m, (int)t, (int)p),
                };
            }
            else
            {
                file = new VaultFile { KeyVault = br.ReadBytes(KeySplit.KeySize) };
            }
        }
        else if (version == VersionMultiSeal)
        {
            br.ReadBytes(3); // flags(1B) + reserved(2B)
            file = new VaultFile
            {
                KeyVault = br.ReadBytes(KeySplit.KeySize),
                Mode = VaultMode.MultiSeal,
            };
            var sealCount = br.ReadByte();
            for (var i = 0; i < sealCount; i++)
            {
                file.Seals.Add(ReadSeal(br));
            }
        }
        else
        {
            throw new InvalidDataException("vault 版本不兼容");
        }
        var count = br.ReadUInt32();
        if (count > VaultLimits.MaxEntries)
            throw new InvalidDataException("vault 条目数异常（可能被恶意构造），拒绝加载");
        for (var i = 0; i < count; i++)
        {
            var uidLen = br.ReadByte();
            var uid = Encoding.UTF8.GetString(br.ReadBytes(uidLen));
            var salt = br.ReadBytes(SaltSize);
            var nonce = br.ReadBytes(NonceSize);
            var ctLen = br.ReadUInt32();
            if (ctLen > VaultLimits.MaxEntryBytes || ctLen > fs.Length - br.BaseStream.Position)
                throw new InvalidDataException("vault 条目长度异常（可能被恶意构造），拒绝加载");
            file.Entries.Add(new VaultEntry
            {
                Uid = uid,
                Salt = salt,
                Nonce = nonce,
                Ciphertext = br.ReadBytes((int)ctLen),
            });
        }
        return file;
    }

    public void Save(string path)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        // 原子写（device-bound-vault-plan §8：写临时文件 → 校验 → 替换，失败保留原文件）
        var tmp = path + ".tmp";
        using (var fs = File.Create(tmp))
        using (var bw = new BinaryWriter(fs))
        {
            WriteBody(bw);
            bw.Flush();
            fs.Flush(flushToDisk: true);
        }
        File.Move(tmp, path, overwrite: true);
    }

    private void WriteBody(BinaryWriter bw)
    {
        bw.Write(Magic);
        var wroteKeyVault = false;
        if (Mode == VaultMode.Password)
        {
            bw.Write(VersionPassword);
            bw.Write((byte)1); // kdf = 口令派生
            bw.Write(new byte[2]);
            bw.Write(Salt!);
            bw.Write((uint)Kdf!.MKiB);
            bw.Write((uint)Kdf.T);
            bw.Write((uint)Kdf.P);
        }
        else if (Mode == VaultMode.MultiSeal)
        {
            bw.Write(VersionMultiSeal);
            bw.Write((byte)0); // flags
            bw.Write(new byte[2]); // reserved
            bw.Write(KeyVault);
            wroteKeyVault = true;
            bw.Write((byte)Seals.Count);
            foreach (var seal in Seals)
            {
                WriteSeal(bw, seal);
            }
        }
        else if (Backend != null)
        {
            // v4：OS 模式 + 后端指纹（解锁时校验，防不同构建形态混用数据目录）
            bw.Write(Version4);
            bw.Write(new byte[3]);
            bw.Write(KeyVault);
            wroteKeyVault = true;
            var b = Encoding.UTF8.GetBytes(Backend);
            if (b.Length > byte.MaxValue) throw new InvalidDataException("后端指纹过长");
            bw.Write((byte)b.Length);
            bw.Write(b);
        }
        else
        {
            bw.Write(Version);
            bw.Write(new byte[3]);
        }
        if (!wroteKeyVault)
        {
            bw.Write(KeyVault);
        }
        bw.Write((uint)Entries.Count);
        foreach (var e in Entries)
        {
            var uidBytes = Encoding.UTF8.GetBytes(e.Uid);
            bw.Write((byte)uidBytes.Length);
            bw.Write(uidBytes);
            bw.Write(e.Salt);
            bw.Write(e.Nonce);
            bw.Write((uint)e.Ciphertext.Length);
            bw.Write(e.Ciphertext);
        }
    }

    /// 加密单条凭据（独立 salt/nonce）。[masterKey] 通常来自 [LockedBuffer]（mlock 区）。
    public VaultEntry Encrypt(string uid, ReadOnlySpan<byte> plaintext, ReadOnlySpan<byte> masterKey)
    {
        var salt = RandomNumberGenerator.GetBytes(SaltSize);
        var nonce = RandomNumberGenerator.GetBytes(NonceSize);
        using var gcm = new AesGcm(masterKey, TagSize);
        var ct = new byte[plaintext.Length + TagSize];
        var tag = ct.AsSpan(plaintext.Length);
        gcm.Encrypt(nonce, plaintext, ct.AsSpan(0, plaintext.Length), tag);
        return new VaultEntry { Uid = uid, Salt = salt, Nonce = nonce, Ciphertext = ct };
    }

    /// 解密单条凭据；GCM 认证失败（篡改/密钥错误）抛 [AuthenticationTagMismatchException]。
    public byte[] Decrypt(VaultEntry entry, ReadOnlySpan<byte> masterKey)
    {
        using var gcm = new AesGcm(masterKey, TagSize);
        var plain = new byte[entry.Ciphertext.Length - TagSize];
        var tag = entry.Ciphertext.AsSpan(plain.Length);
        gcm.Decrypt(entry.Nonce, entry.Ciphertext.AsSpan(0, plain.Length), tag, plain);
        return plain;
    }

    /// 从磁盘读取字节（测试用：验证「磁盘无明文」）。
    public static byte[] RawBytes(string path) => File.ReadAllBytes(path);
}
