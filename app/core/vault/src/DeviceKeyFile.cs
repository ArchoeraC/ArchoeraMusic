// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Security.Cryptography;

namespace Archoera.Vault;

/// 设备密钥文件（`device.key`，F2）：32B 随机设备材料，仅存本地 0600 文件。
///
/// deviceSecret 参与设备槽 / 口令+设备槽的 KEK 派生；文件缺失即设备因子不可用
/// （m2a 口令路径 → NEED_RECOVERY 改用恢复码；m2b → 无法解锁）。
/// 注意：本阶段仅本地明文文件（0600），尚未接入 OS 钥匙串（后续阶段）。
public static class DeviceKeyFile
{
    public const string FileName = "device.key";

    /// 设备材料长度（与主密钥同宽）。
    public const int KeySize = KeySplit.KeySize;

    public static string PathFor(string dataDir) => Path.Combine(dataDir, FileName);

    public static bool Exists(string dataDir) => File.Exists(PathFor(dataDir));

    /// 生成 32B 随机设备材料并落盘（0600 原子写），返回该材料（调用方用后清零）。
    public static byte[] CreateAndSave(string dataDir)
    {
        var key = RandomNumberGenerator.GetBytes(KeySize);
        Save(dataDir, key);
        return key;
    }

    /// 读取设备材料；文件缺失抛 [NeedRecoveryException]（环境缺失，非爆破向量）。
    /// 返回新数组，调用方用后须 [CryptographicOperations.ZeroMemory]。
    public static byte[] Load(string dataDir)
    {
        var path = PathFor(dataDir);
        if (!File.Exists(path))
        {
            throw new NeedRecoveryException(
                "设备密钥缺失（device.key 不存在）：设备因子不可用，请改用恢复码解锁");
        }
        var raw = File.ReadAllBytes(path);
        if (raw.Length != KeySize)
        {
            CryptographicOperations.ZeroMemory(raw);
            throw new InvalidDataException($"device.key 长度异常（{raw.Length} 字节，应为 {KeySize}）");
        }
        return raw;
    }

    /// 原子写（tmp + 0600 + rename；失败保留原文件）。
    public static void Save(string dataDir, byte[] key)
    {
        if (key.Length != KeySize)
            throw new ArgumentException($"设备材料须为 {KeySize} 字节", nameof(key));
        Directory.CreateDirectory(dataDir);
        var path = PathFor(dataDir);
        var tmp = path + ".tmp";
        File.WriteAllBytes(tmp, key);
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(tmp, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        File.Move(tmp, path, overwrite: true);
    }

    /// 删除设备材料（不存在则忽略）。
    public static void Delete(string dataDir)
    {
        var path = PathFor(dataDir);
        if (File.Exists(path)) File.Delete(path);
    }
}
