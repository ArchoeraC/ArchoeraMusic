using System.Security.Cryptography;

namespace Archoera.Vault;

/// 主密钥 2-of-2 协同拆分（credential-vault-plan §3.2.1）。
///
/// 随机主密钥 K 拆为两份份额，缺一不可：
///   - S（shareS）：锚定「系统授权」侧（OS 安全存储：DPAPI/Keychain/libsecret）；
///   - K_vault（keyVault）：随 vault 文件存储（由 OS 安全存储保护其密文存储）。
/// 解密需 vault 侧（K_vault）+ 授权侧（S）同时在场：K = K_vault ⊕ S。
/// 攻击者仅持 vault 文件（缺 S）或仅源码/口令哈希（缺熵源）均不足以解密。
public static class KeySplit
{
    public const int KeySize = 32;

    /// 生成新主密钥并拆分。调用方必须妥善持久化两份份额（[shareS] 交 OS 安全存储）。
    public static (byte[] keyVault, byte[] shareS) Split()
    {
        var master = RandomNumberGenerator.GetBytes(KeySize);
        var s = RandomNumberGenerator.GetBytes(KeySize);
        var kv = new byte[KeySize];
        for (var i = 0; i < KeySize; i++) kv[i] = (byte)(master[i] ^ s[i]);
        CryptographicOperations.ZeroMemory(master);
        return (kv, s);
    }

    /// 协同重建主密钥：K = keyVault ⊕ shareS（返回新数组）。
    public static byte[] Recombine(byte[] keyVault, byte[] shareS)
    {
        var r = new byte[KeySize];
        Recombine(keyVault, shareS, r);
        return r;
    }

    /// 协同重建主密钥：写入调用方提供的目标缓冲（典型为 [LockedBuffer] 的 mlock 区，
    /// 重建后即处于锁定内存，避免中间态泄露到可换页堆）。
    public static void Recombine(ReadOnlySpan<byte> keyVault, ReadOnlySpan<byte> shareS, Span<byte> dest)
    {
        if (keyVault.Length != KeySize || shareS.Length != KeySize || dest.Length != KeySize)
        {
            throw new ArgumentException($"份额长度必须为 {KeySize} 字节");
        }
        for (var i = 0; i < KeySize; i++) dest[i] = (byte)(keyVault[i] ^ shareS[i]);
    }
}
