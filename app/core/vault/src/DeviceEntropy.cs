using System.Security.Cryptography;

namespace Archoera.Vault;

/// 设备熵文件（`device.seal`，device-bound-vault-plan §4.2）与熵绑定密钥派生（§5.2）。
///
/// 模型（BitLocker TPM 封装的软件等价物）：
///   - 熵本体 E（32B 随机）仅以密文落盘（device.seal），解开后短暂存在于
///     锁定内存（调用方 LockedBuffer），用后 zeroize；
///   - 熵绑定密钥 K_bind = HKDF-SHA256(设备指纹, salt, info="archoera.device-entropy")
///     每次使用临时派生、不持久化（指纹公开后密钥不长期有效）；
///   - 份额密封密钥 K_seal = HKDF-SHA256(E, info="archoera.share-seal") 密封授权侧
///     份额 S（vault v3 kind=2 封装）——熵本体与 S 密文分置（vault / device.seal），
///     拷贝任一文件均不足以解密。
/// 熵本体 E 只在解锁链中出现：指纹 → K_bind → E → K_seal → S → K。
public sealed class DeviceEntropyFile
{
    public const string FileName = "device.seal";
    public const uint Magic = 0x58564441; // "AVDX"（小端）
    public const int Version = 1;
    public const int EntropyIdSize = 32;
    public const int SaltSize = 16;
    public const int NonceSize = 12;
    public const int TagSize = 16;
    public const int EntropySize = 32;

    /// 熵密封 info 串（§5.2）。
    public const string BindInfo = "archoera.device-entropy";

    /// 份额密封 info 串（熵 → K_seal）。
    public const string ShareSealInfo = "archoera.share-seal";

    public required byte[] EntropyId { get; init; }
    public required byte[] Salt { get; init; }
    public required byte[] Nonce { get; init; }
    public required byte[] Ciphertext { get; init; } // ct|tag = 32+16 = 48B

    /// 生成新熵并返回（调用方须用后 [CryptographicOperations.ZeroMemory]；
    /// 落盘由 [SealAndSave] 完成）。随机 entropy_id/salt/nonce。
    public static DeviceEntropyFile Create()
    {
        var id = RandomNumberGenerator.GetBytes(EntropyIdSize);
        var salt = RandomNumberGenerator.GetBytes(SaltSize);
        var nonce = RandomNumberGenerator.GetBytes(NonceSize);
        return new DeviceEntropyFile
        {
            EntropyId = id,
            Salt = salt,
            Nonce = nonce,
            Ciphertext = [], // 未密封（占位；SealAndSave 前不落盘）
        };
    }

    /// 用指纹密封熵并落盘（原子写：临时文件 + 替换）。[entropy] 调用方所有，用后清零。
    public void SealAndSave(string path, byte[] entropy, string fingerprint)
    {
        var key = BindKey(fingerprint, Salt);
        var ct = new byte[EntropySize + TagSize];
        var tag = ct.AsSpan(EntropySize);
        using (var gcm = new AesGcm(key, TagSize))
        {
            gcm.Encrypt(Nonce, entropy, ct.AsSpan(0, EntropySize), tag);
        }
        CryptographicOperations.ZeroMemory(key);
        var file = new DeviceEntropyFile
        {
            EntropyId = EntropyId,
            Salt = Salt,
            Nonce = Nonce,
            Ciphertext = ct,
        };
        file.Save(path);
    }

    /// 从磁盘加载（不解密）。
    public static DeviceEntropyFile Load(string path)
    {
        using var fs = File.OpenRead(path);
        using var br = new BinaryReader(fs);
        if (br.ReadUInt32() != Magic) throw new InvalidDataException("device.seal 头损坏（magic 不符）");
        var version = br.ReadByte();
        var kdf = br.ReadByte();
        br.ReadBytes(2);
        if (version != Version || kdf != 1) throw new InvalidDataException("device.seal 版本/算法不兼容");
        var id = br.ReadBytes(EntropyIdSize);
        var salt = br.ReadBytes(SaltSize);
        var nonce = br.ReadBytes(NonceSize);
        var ct = br.ReadBytes(EntropySize + TagSize);
        return new DeviceEntropyFile { EntropyId = id, Salt = salt, Nonce = nonce, Ciphertext = ct };
    }

    /// 解封熵本体（指纹在场）；GCM 认证失败（指纹不符/篡改）抛 [CryptographicException]。
    /// 返回新数组（32B），调用方须尽快复制进锁定内存并用后 zeroize。
    public byte[] Unseal(string fingerprint)
    {
        if (Ciphertext.Length != EntropySize + TagSize)
        {
            throw new InvalidDataException("device.seal 熵密文长度异常");
        }
        var key = BindKey(fingerprint, Salt);
        var e = new byte[EntropySize];
        var tag = Ciphertext.AsSpan(EntropySize);
        try
        {
            using var gcm = new AesGcm(key, TagSize);
            gcm.Decrypt(Nonce, Ciphertext.AsSpan(0, EntropySize), tag, e);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
        }
        return e;
    }

    /// 熵绑定密钥：K_bind = HKDF-SHA256(指纹, salt, info=BindInfo)。每次调用临时派生。
    public static byte[] BindKey(string fingerprint, byte[] salt)
    {
        return HKDF.DeriveKey(HashAlgorithmName.SHA256,
            System.Text.Encoding.UTF8.GetBytes(fingerprint),
            EntropySize, salt, System.Text.Encoding.UTF8.GetBytes(BindInfo));
    }

    /// 份额密封密钥：K_seal = HKDF-SHA256(熵, info=ShareSealInfo)。
    /// [entropy] 通常来自锁定内存（LockedBuffer.Span），用后由 [VaultService] 清零。
    public static byte[] ShareSealKey(ReadOnlySpan<byte> entropy)
    {
        return HKDF.DeriveKey(HashAlgorithmName.SHA256, entropy.ToArray(),
            EntropySize, salt: null, System.Text.Encoding.UTF8.GetBytes(ShareSealInfo));
    }

    public void Save(string path)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        using var fs = File.Create(path);
        using var bw = new BinaryWriter(fs);
        bw.Write(Magic);
        bw.Write((byte)Version);
        bw.Write((byte)1); // kdf = HKDF-SHA256
        bw.Write(new byte[2]);
        bw.Write(EntropyId);
        bw.Write(Salt);
        bw.Write(Nonce);
        bw.Write(Ciphertext);
        bw.Flush();
        fs.Flush(flushToDisk: true);
    }

    /// 自检（熵密封往返 + 异指纹 GCM 拦截 + S 份额密封往返）：
    /// 同指纹解封等值、异指纹必须失败、篡改必须失败。
    public static bool SelfTest()
    {
        const string fpA = "selftest-fingerprint-A";
        var entropy = RandomNumberGenerator.GetBytes(EntropySize);
        var share = RandomNumberGenerator.GetBytes(KeySplit.KeySize);
        var path = Path.Combine(Path.GetTempPath(), "archoera-seal-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            // ① 熵密封 → 落盘 → 同指纹解封等值
            var dev = Create();
            dev.SealAndSave(path, entropy, fpA);
            var back = Load(path).Unseal(fpA);
            var ok = CryptographicOperations.FixedTimeEquals(entropy, back);
            CryptographicOperations.ZeroMemory(back);
            if (!ok) return false;

            // ② 异指纹解封必须失败（GCM 认证拦截，换机语义）
            try
            {
                Load(path).Unseal("selftest-fingerprint-B");
                return false;
            }
            catch (CryptographicException)
            {
                // 预期
            }

            // ③ 篡改密文必须失败（GCM 认证拦截，fail-closed）
            var raw = File.ReadAllBytes(path);
            raw[^1] ^= 0x01;
            File.WriteAllBytes(path, raw);
            try
            {
                Load(path).Unseal(fpA);
                return false;
            }
            catch (CryptographicException)
            {
                // 预期
            }

            // ④ S 份额密封往返（熵派生 K_seal → SealShareWithEntropy → UnsealShare）
            var kSeal = ShareSealKey(entropy);
            var seal = VaultService.SealShareWithEntropy(share, kSeal, dev.EntropyId);
            var shareBack = VaultService.UnsealShare(seal, kSeal);
            var okShare = CryptographicOperations.FixedTimeEquals(share, shareBack);
            CryptographicOperations.ZeroMemory(kSeal);
            CryptographicOperations.ZeroMemory(shareBack);
            if (!okShare) return false;
            return true;
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
            CryptographicOperations.ZeroMemory(entropy);
            CryptographicOperations.ZeroMemory(share);
        }
    }
}
