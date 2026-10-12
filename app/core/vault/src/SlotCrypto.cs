// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Security.Cryptography;
using System.Text;

namespace Archoera.Vault;

/// 'S'（slots）容器槽位 KEK 派生（F2）。
///
/// 每个槽位 kind 用不同 KDF 组合把「因子材料」映射为 32B 的 KEK（包裹主密钥 K）；
/// info 串与 `ad = vaultId‖kind` 提供域分离，任一 kind 的派生互不通用。
///   - 口令（1）：Argon2id(口令, salt, ad)          —— 抗 GPU 爆破，参数随槽存；
///   - 设备（2）：HKDF-SHA256(deviceSecret, salt, "archoera.slot.device")；
///   - 恢复（3）：HKDF-SHA256(recoveryCodeBytes, salt, "archoera.slot.recovery")；
///   - 口令+设备（4）：HKDF-SHA256(Argon2id(口令, salt, ad) ‖ deviceSecret,
///                     salt, "archoera.slot.pwdev") —— 不做二次 Argon2id。
public static class SlotCrypto
{
    public const string DeviceInfo = "archoera.slot.device";
    public const string RecoveryInfo = "archoera.slot.recovery";
    public const string PasswordDeviceInfo = "archoera.slot.pwdev";

    /// 口令槽 KEK = Argon2id(口令, salt, secret=[], ad=vaultId‖kind)。
    public static byte[] DerivePassword(
        byte[] password, byte[] salt, ReadOnlySpan<byte> ad, Argon2id.KdfParams kdf)
        => Argon2id.Derive(password, salt, [], ad, kdf.MKiB, kdf.T, kdf.P, KeySplit.KeySize);

    /// 设备槽 KEK = HKDF-SHA256(deviceSecret, salt, info="archoera.slot.device")。
    public static byte[] DeriveDevice(ReadOnlySpan<byte> deviceSecret, byte[] salt)
        => HKDF.DeriveKey(HashAlgorithmName.SHA256, deviceSecret.ToArray(), KeySplit.KeySize,
            salt, Encoding.UTF8.GetBytes(DeviceInfo));

    /// 恢复槽 KEK = HKDF-SHA256(recoveryCodeBytes, salt, info="archoera.slot.recovery")。
    public static byte[] DeriveRecovery(ReadOnlySpan<byte> recoveryCodeBytes, byte[] salt)
        => HKDF.DeriveKey(HashAlgorithmName.SHA256, recoveryCodeBytes.ToArray(), KeySplit.KeySize,
            salt, Encoding.UTF8.GetBytes(RecoveryInfo));

    /// 口令+设备槽 KEK = HKDF-SHA256(base ‖ deviceSecret, salt, info="archoera.slot.pwdev")。
    /// [base] 为 Argon2id(口令) 输出；拼接缓冲用后立即清零。
    public static byte[] DerivePasswordDevice(
        ReadOnlySpan<byte> baseKey, ReadOnlySpan<byte> deviceSecret, byte[] salt)
    {
        var ikm = new byte[baseKey.Length + deviceSecret.Length];
        baseKey.CopyTo(ikm);
        deviceSecret.CopyTo(ikm.AsSpan(baseKey.Length));
        try
        {
            return HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, KeySplit.KeySize,
                salt, Encoding.UTF8.GetBytes(PasswordDeviceInfo));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(ikm);
        }
    }
}
