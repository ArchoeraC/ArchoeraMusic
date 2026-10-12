// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Buffers.Binary;

namespace Archoera.Vault;

/// 份额 + 解锁退避状态的同槽承载（[security-review SEC-05]）。
///
/// 目的：把 [VaultLockout] 的退避状态**内嵌进已存于 `master-share` 槽位的值**，
/// 使「删除/重置退避」必须连同销毁份额一起进行——单槽后端（[FileStore] /
/// [DpapiStore]）会因此直接砖化 vault，多槽后端（Keychain/Libsecret/Insecure）
/// 也不再是独立可删条目，攻击者无法只清退避来无限次在线爆破。
///
/// 布局（小端）：
///   magic(4)="ASTB" | version(1)=1 | shareLen(1)=32 | share(32)
///   | failures(int32 LE) | until(int64 LE)           —— 共 50 字节
///
/// 向后兼容：旧库在 `master-share` 槽位只存 32 字节原始份额/K（无 lockout）——
/// [Decode] 识别为 legacy 原始份额（failures/until 视为 0），解锁行为不变；
/// 之后任一失败会就地升级为 bundle 并以 `SetShare` 重新落盘。
internal static class ShareBundle
{
    public const int MaxFailures = 10;
    public const byte Version = 1;

    public const int VersionOffset = 4;
    public const int ShareLenOffset = 5;
    public const int ShareOffset = 6;
    public const int FailuresOffset = ShareOffset + KeySplit.KeySize; // 38
    public const int UntilOffset = FailuresOffset + sizeof(int);      // 42
    public const int Size = UntilOffset + sizeof(long);               // 50

    private static readonly byte[] Magic = { (byte)'A', (byte)'S', (byte)'T', (byte)'B' };

    /// 解码槽位值：
    ///   null                 → (null, 0, 0)（无份额）
    ///   32B                  → (raw, 0, 0)（legacy 原始份额/K）
    ///   合法 bundle          → (share, clamp(failures,[0,10]), until)
    ///   其他/损坏            → (null, 0, 0)（视为份额缺失，fail-closed）
    public static (byte[]? share, int failures, long until) Decode(byte[]? raw)
    {
        if (raw == null) return (null, 0, 0);
        if (raw.Length == KeySplit.KeySize) return (raw, 0, 0); // legacy 原始份额/K
        if (raw.Length >= Size
            && raw.AsSpan(0, Magic.Length).SequenceEqual(Magic)
            && raw[VersionOffset] == Version
            && raw[ShareLenOffset] == KeySplit.KeySize)
        {
            var failures = Math.Clamp(
                BinaryPrimitives.ReadInt32LittleEndian(raw.AsSpan(FailuresOffset)), 0, MaxFailures);
            var until = BinaryPrimitives.ReadInt64LittleEndian(raw.AsSpan(UntilOffset));
            var share = raw.AsSpan(ShareOffset, KeySplit.KeySize).ToArray();
            return (share, failures, until);
        }
        return (null, 0, 0); // 未知/损坏 → 份额缺失（fail-closed）
    }

    /// 编码份额 + 退避状态；调用方负责份额缓冲的清零。
    public static byte[] Encode(byte[] share, int failures, long until)
    {
        if (share.Length != KeySplit.KeySize)
        {
            throw new ArgumentException($"份额须为 {KeySplit.KeySize} 字节");
        }
        var buf = new byte[Size];
        Magic.CopyTo(buf, 0);
        buf[VersionOffset] = Version;
        buf[ShareLenOffset] = KeySplit.KeySize;
        share.CopyTo(buf, ShareOffset);
        BinaryPrimitives.WriteInt32LittleEndian(
            buf.AsSpan(FailuresOffset), Math.Clamp(failures, 0, MaxFailures));
        BinaryPrimitives.WriteInt64LittleEndian(buf.AsSpan(UntilOffset), until);
        return buf;
    }
}
