// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Security.Cryptography;
using System.Text;

namespace Archoera.Vault;

/// vault 文件格式：
/// ```
/// version 字段（1B）= 模式代号——一模式一字母（大写），新增模式用新字母，
/// 不与历史数字布局纠缠：
///   'C'(0x43) LEGACY（crypto 传统单因子）：K 整体存 OS 安全存储，文件无密钥材料
///   'S'(0x53) slots 容器：头部槽位表封装 K，条目以 K 加密，尾部 HMAC 锚定
/// 通用布局：
///   magic "AVLT"(4B) | version(1B) | 头部(按模式)… | entry_count(u32) | entries…
///   entry: uid_len(1B) | uid(utf8) | salt(16B) | nonce(12B) | ct_len(u32) | ciphertext(ct|tag)
/// 'C'：reserved(3B) | key_vault(32B, 零占位) | backend_len(1B) | backend(utf8)
/// 'S'：vault_id(16B) | created_at_ms(i64) | alg(1B=1 AES-256-GCM) | slot_count(1B)
///      | slot[slot_count] | entry_count(u32) | entries… | trailer(32B, HMAC-SHA256(K, 前文))
///      slot: kind(1B) | m(u32) | t(u32) | p(u32) | salt(16B) | nonce(12B)
///            | wrapped_len(u16) | wrapped(ct‖tag, K 的封装)
///      kind 1=口令 2=设备 3=恢复 4=口令+设备（m/t/p 仅口令类槽有意义）
/// ```
/// LEGACY（'C'）：单因子——key_vault 字段不承载份额（32B 零占位），主密钥 K 整体存
/// OS 安全存储（vault 文件不含密钥材料，窃取文件无 K 无法解密）；backend 指纹照常
/// 校验（防不同存储后端（file/libsecret/dpapi/keychain）混用同一数据目录）。
/// 每条目独立 salt/nonce，AES-256-GCM（tag 16B 附于密文尾）。
/// 'S' slots：无 K_vault 份额概念——K 由槽位表封装（F1 仅口令槽 kind=1，KEK =
/// Argon2id(口令, ad = vault_id‖kind)），条目直接以 K 加密；尾部
/// HMAC-SHA256(K, header‖entries) 在解密凭据前校验（verify-before-decrypt）。
public enum VaultMode
{
    /// LEGACY（crypto 传统单因子，推荐）：主密钥 K 整体存 OS 安全存储，vault 文件
    /// 不含密钥材料（key_vault=32B 零占位）；条目仍 AES-256-GCM 加密落盘。
    Crypto = 0,

    /// 新槽位容器（'S'，slots）：主密钥 K 整体由「槽位表」中的封装承载
    /// （F1 仅口令封装 kind=1），条目以 K 直接 AES-256-GCM 加密，尾部
    /// HMAC-SHA256(K, header‖entries) 提供 verify-before-decrypt。
    Slots = 1,
}

/// 槽位表中单个槽位的封装类型（'S' 容器）。
/// 每个 kind 决定 KEK 的派生方式（见 [SlotCrypto]），包裹的主密钥 K 与
/// `ad = vaultId‖kind`、AES-256-GCM 语义对所有 kind 一致。
public enum SlotKind : byte
{
    /// 口令槽：KEK = Argon2id(口令, salt, ad=vaultId‖kind)。
    Password = 1,

    /// 设备熵槽（F2）：KEK = HKDF-SHA256(deviceSecret, salt, info="archoera.slot.device")。
    Device = 2,

    /// 恢复槽（F2）：KEK = HKDF-SHA256(recoveryCodeBytes, salt, info="archoera.slot.recovery")。
    Recovery = 3,

    /// 口令 + 设备双因子槽（F2）：
    /// KEK = HKDF-SHA256(Argon2id(口令)‖deviceSecret, salt, info="archoera.slot.pwdev")。
    PasswordDevice = 4,
}

/// 'S'（slots）容器的**因子模式**（由槽位集合推导，不写入文件头——
/// 容器 version 恒为 'S'，模式是槽位表的函数）。
public enum SlotsMode
{
    /// 未知 / 空槽位集合。
    None = 0,

    /// m1：恰好一个口令槽。
    M1 = 1,

    /// m2a：口令+设备双因子槽（+ 恢复槽）——口令 + device.key，或恢复码。
    M2a = 2,

    /// m2b：仅设备槽——仅需 device.key（本机免密）。
    M2b = 3,
}

/// 加载上限（防恶意构造的 vault 文件 DoS，credential-vault-plan §8）：
/// 正常库仅 KB 级（每条目 ≤1KB，万条也 <10MB）——16MB/10 万条目/单条目 4MB
/// 留足余量；超限文件视为攻击（[VaultFile.Load] 快速拒绝，不分配/不循环）。
public static class VaultLimits
{
    public const long MaxFileSize = 16 * 1024 * 1024;
    public const uint MaxEntries = 100_000;
    public const int MaxEntryBytes = 4 * 1024 * 1024;

    // ── KDF 参数加载上限（SEC-06）──
    // 口令封装头部的 m/t/p 为 u32 且不受文件大小约束；恶意构造 m≈2^32 会在
    // 任何认证之前触发巨量内存分配（解锁前 DoS）。正常档 64 MiB/3/1，
    // 自检向量最大用到 m=65536/p=4，故上限留足余量（256 MiB / 16 轮 / 8 通道）。
    public const int MaxKdfMemoryKiB = 256 * 1024;
    public const int MaxKdfIterations = 16;
    public const int MaxKdfParallelism = 8;

    // ── KDF 参数下界（F1）──
    // 口令槽拒绝过弱的 KDF 参数（如 m=1024 / t=0），避免「防 GPU 爆破」形同虚设。
    public const int MinKdfMemoryKiB = 8192;
    public const int MinKdfIterations = 1;
    public const int MinKdfParallelism = 1;

    /// 校验 KDF 参数是否在允许区间；越界抛 [InvalidDataException]（加载/派生前快速拒绝）。
    /// 下界（F1 新增）：m ≥ 8192 KiB、t ≥ 1、p ≥ 1——防止用极弱 KDF 参数构造口令槽
    /// 绕过「防 GPU 爆破」的设计目标；上界沿用 SEC-06 的快速拒绝。
    public static void ValidateKdf(int mKiB, int t, int p)
    {
        if (p < MinKdfParallelism || p > MaxKdfParallelism)
            throw new InvalidDataException($"KDF 并行度参数异常（p={p}），拒绝加载");
        if (mKiB < MinKdfMemoryKiB || mKiB > MaxKdfMemoryKiB)
            throw new InvalidDataException($"KDF 内存参数异常（m={mKiB} KiB），拒绝加载");
        if (t < MinKdfIterations || t > MaxKdfIterations)
            throw new InvalidDataException($"KDF 迭代次数异常（t={t}），拒绝加载");
    }
}

/// 'S'（slots）容器的单个槽位：以某个 KEK 封装主密钥 K。
/// F1 仅口令槽（[SlotKind.Password]）：KEK = Argon2id(口令, salt, ad=vaultId‖kind)，
/// 封装 = AES-256-GCM(KEK, K)，[Wrapped] = ct(32B)‖tag(16B)。
public sealed class VaultSlot
{
    public required SlotKind Kind { get; init; }

    /// 槽位 KDF 参数。口令 / 口令+设备槽为 Argon2id 参数；
    /// 设备 / 恢复槽不使用 KDF 参数（占位 (0,0,0)，加载时跳过下界校验）。
    public required Argon2id.KdfParams Kdf { get; init; }

    /// 槽位 KDF 盐（16B）。
    public required byte[] Salt { get; init; }

    /// 封装 nonce（12B）。
    public required byte[] Nonce { get; init; }

    /// 被封装的 K（ct‖tag；口令槽 = K 的 AES-256-GCM 密文）。
    public required byte[] Wrapped { get; init; }
}

/// 文件头元数据（非密文，供 serve 握手前读取模式/参数）。
/// 'C' 返回 [Backend]（后端指纹）；'S' 返回 [SlotKinds]（只读 kind 列表，
/// 不加载密文）——serve/status 据此判定 m1/m2a/m2b。
/// [Kdf] 为**口令承载槽**（口令 / 口令+设备）的 Argon2id 参数（m1/m2a 可用；
/// 设备/恢复槽或 crypto 模式为 null）——供 status 展示当前强度，不加载任何密文。
public sealed record VaultHeader(
    VaultMode Mode,
    string? Backend = null,
    IReadOnlyList<SlotKind>? SlotKinds = null,
    Argon2id.KdfParams? Kdf = null);

public sealed class VaultFile
{
    public const uint Magic = 0x544C5641; // "AVLT"（小端）

    // ── 文件头 version 字段（1B）= 模式代号（一模式一字母，新增模式用新字母）──
    public const byte ModeCrypto = (byte)'C';    // LEGACY（crypto 传统单因子）
    public const byte ModeSlots = (byte)'S';     // 新槽位容器（头部 HMAC 锚定条目）

    public const int SaltSize = 16;
    public const int NonceSize = 12;
    public const int TagSize = 16;

    // ── 'S'（slots）容器常量 ──
    public const int VaultIdSize = 16;        // 随机库标识（KDF/GCM 的 AD 域分离）
    public const byte AlgAes256Gcm = 1;       // 条目加密算法（F1 唯一取值）
    public const int TrailerSize = 32;        // 尾部 HMAC-SHA256(K, header‖entries)

    /// 头部 K_vault 份额（32B，明文写盘——单独无法解密，见 [KeySplit]；
    /// LEGACY crypto 为 32B 零占位，slots 无此概念亦为零占位）。
    public required byte[] KeyVault { get; init; }

    /// 份额锚定方式（LEGACY crypto / 'S' slots）。
    public VaultMode Mode { get; init; } = VaultMode.Crypto;

    /// LEGACY crypto 记录的后端指纹（[VaultService.Backend]）。
    public string? Backend { get; init; }

    // ── 'S'（slots）容器字段（非该模式时为 null/0/空）──

    /// 库标识（16B，随机；KDF 与 GCM 的 AD = vaultId‖kind）。
    public byte[]? VaultId { get; init; }

    /// 创建时刻（Unix 毫秒）。
    public long CreatedAtMs { get; init; }

    /// 条目加密算法标识（[AlgAes256Gcm]）。
    public byte Alg { get; init; }

    /// 槽位表（F1：单个口令槽）。
    public List<VaultSlot> Slots { get; } = new();

    /// 从磁盘读出的尾部 HMAC（32B；仅 [Load] 填充）。
    public byte[]? Trailer { get; set; }

    /// 尾部 HMAC 的输入字节（raw[0 .. raw.Length-32]；仅 [Load] 填充）。
    public byte[]? MacInput { get; set; }

    public List<VaultEntry> Entries { get; } = new();

    public sealed class VaultEntry
    {
        public required string Uid { get; init; }
        public required byte[] Salt { get; init; }
        public required byte[] Nonce { get; init; }
        public required byte[] Ciphertext { get; init; }
    }

    /// LEGACY（crypto）方案工厂（单因子，推荐）：主密钥 K 整体存 OS 安全存储，
    /// 文件不含密钥材料——key_vault 为 32B 零占位（[VaultService.InitCrypto]）。
    /// 写 'C' 代号并记录存储后端指纹（[backend] 非 null）。
    public static VaultFile CreateCrypto(string backend)
        => new() { KeyVault = new byte[KeySplit.KeySize], Mode = VaultMode.Crypto, Backend = backend };

    /// 'S'（slots）容器工厂：头部 = vaultId/createdAt/alg + 槽位表；无 K_vault 份额
    /// 概念（条目直接以 K 加密），故 key_vault 为 32B 零占位。写入时须向
    /// [Save] 传入主密钥 K 以计算尾部 HMAC。
    public static VaultFile CreateSlots(byte[] vaultId, long createdAtMs, byte alg,
        IReadOnlyList<VaultSlot> slots)
    {
        var f = new VaultFile
        {
            KeyVault = new byte[KeySplit.KeySize],
            Mode = VaultMode.Slots,
            VaultId = vaultId,
            CreatedAtMs = createdAtMs,
            Alg = alg,
        };
        f.Slots.AddRange(slots);
        return f;
    }

    /// 槽位 AD（域分离）= vaultId ‖ kind（KDF 与 AES-GCM 共用同一 AD）。
    public static byte[] BuildSlotAd(byte[] vaultId, SlotKind kind)
    {
        var ad = new byte[vaultId.Length + 1];
        vaultId.CopyTo(ad, 0);
        ad[^1] = (byte)kind;
        return ad;
    }

    /// 由槽位集合推导因子模式（m1 / m2a / m2b）。优先级：
    /// 单口令槽 → m1；含口令+设备双因子槽 → m2a；含设备槽 → m2b；
    /// 其余（空/未知组合）→ [SlotsMode.None]。
    public static SlotsMode DetectSlotsMode(IReadOnlyList<SlotKind> kinds)
    {
        if (kinds.Count == 1 && kinds[0] == SlotKind.Password) return SlotsMode.M1;
        if (kinds.Any(k => k == SlotKind.PasswordDevice)) return SlotsMode.M2a;
        if (kinds.Any(k => k == SlotKind.Device)) return SlotsMode.M2b;
        return SlotsMode.None;
    }

    /// 尾部完整性 MAC = HMAC-SHA256(K, header‖entries)。
    /// K 由槽位解出后立即校验（在解密任何条目之前）——header/槽位表/条目任一被篡改
    /// 都会在凭据解密前 fail-closed（verify-before-decrypt）。
    public static byte[] ComputeSlotsMac(ReadOnlySpan<byte> masterKey, ReadOnlySpan<byte> body)
        => HMACSHA256.HashData(masterKey, body);

    /// 仅读文件头（magic/version/参数）——serve 握手前判定模式用，
    /// 不加载/解密任何凭据（§3.8 握手前置：构造只触盘读文件头）。
    public static VaultHeader ReadHeader(string path)
    {
        using var fs = File.OpenRead(path);
        using var br = new BinaryReader(fs);
        if (br.ReadUInt32() != Magic) throw new InvalidDataException("vault 文件头损坏（magic 不符）");
        var version = br.ReadByte();
        return version switch
        {
            ModeCrypto => ReadHeaderCrypto(br),
            ModeSlots => ReadHeaderSlots(br),
            _ => throw new InvalidDataException("vault 版本不兼容"),
        };
    }

    /// 读 LEGACY（crypto）头部：key_vault 零占位（不含密钥材料）+ 后端指纹。
    private static VaultHeader ReadHeaderCrypto(BinaryReader br)
    {
        br.ReadBytes(3);
        br.ReadBytes(KeySplit.KeySize); // 零占位，不含密钥材料
        return new VaultHeader(VaultMode.Crypto, ReadBackend(br));
    }

    /// 读 'S'（slots）头部：vaultId/createdAt/alg + 槽位表（口令类槽校验 KDF 参数）。
    /// 头部不含任何明文凭据；口令槽 KDF 越界（含新增下界）在此快速拒绝。
    /// 返回槽位 kind 列表（只读）——serve/status 据此判定 m1/m2a/m2b，不加载密文；
    /// 同时捕获口令承载槽（口令 / 口令+设备）的 KDF 参数供 status 展示强度。
    private static VaultHeader ReadHeaderSlots(BinaryReader br)
    {
        br.ReadBytes(VaultIdSize); // vaultId
        br.ReadBytes(sizeof(long)); // createdAtMs
        br.ReadByte(); // alg
        var slotCount = br.ReadByte();
        var kinds = new List<SlotKind>(slotCount);
        Argon2id.KdfParams? kdf = null;
        for (var i = 0; i < slotCount; i++)
        {
            var slot = ReadSlot(br);
            kinds.Add(slot.Kind);
            // 口令承载槽（m1 的口令槽 / m2a 的口令+设备槽）：首个即当前 KDF 强度
            if (kdf == null && slot.Kind is SlotKind.Password or SlotKind.PasswordDevice)
                kdf = slot.Kdf;
        }
        return new VaultHeader(VaultMode.Slots, SlotKinds: kinds, Kdf: kdf);
    }

    /// 读单个槽位（kind + KDF 参数 + salt + nonce + wrapped）。
    /// 口令 / 口令+设备槽的 m/t/p 走 [ValidateKdf]（上下界快速拒绝）；
    /// 设备 / 恢复槽的参数不使用（占位 (0,0,0)），直接读值不校验。
    private static VaultSlot ReadSlot(BinaryReader br)
    {
        var kind = (SlotKind)br.ReadByte();
        if ((byte)kind is < 1 or > 4)
            throw new InvalidDataException($"未知槽位类型 {(byte)kind}");
        var kdf = kind is SlotKind.Password or SlotKind.PasswordDevice
            ? ReadKdf(br) // 立即做上/下界校验（SEC-06 + F1 下界）
            : new Argon2id.KdfParams((int)br.ReadUInt32(), (int)br.ReadUInt32(), (int)br.ReadUInt32());
        var salt = br.ReadBytes(SaltSize);
        var nonce = br.ReadBytes(NonceSize);
        var wrappedLen = br.ReadUInt16();
        if (wrappedLen < KeySplit.KeySize)
            throw new InvalidDataException("槽位封装长度异常（小于主密钥），拒绝加载");
        var wrapped = br.ReadBytes(wrappedLen);
        return new VaultSlot
        {
            Kind = kind, Kdf = kdf, Salt = salt, Nonce = nonce, Wrapped = wrapped,
        };
    }

    /// 写单个槽位（kind + KDF 参数 + salt + nonce + wrappedLen + wrapped）。
    private static void WriteSlot(BinaryWriter bw, VaultSlot slot)
    {
        bw.Write((byte)slot.Kind);
        bw.Write((uint)slot.Kdf.MKiB);
        bw.Write((uint)slot.Kdf.T);
        bw.Write((uint)slot.Kdf.P);
        bw.Write(slot.Salt);
        bw.Write(slot.Nonce);
        if (slot.Wrapped.Length > ushort.MaxValue)
            throw new InvalidDataException("槽位封装过长");
        bw.Write((ushort)slot.Wrapped.Length);
        bw.Write(slot.Wrapped);
    }

    /// 读后端指纹（1B 长度 + UTF8；长度 0 视为无指纹）。
    private static string? ReadBackend(BinaryReader br)
    {
        var len = br.ReadByte();
        return len == 0 ? null : Encoding.UTF8.GetString(br.ReadBytes(len));
    }

    /// 读 KDF 参数（m/t/p）并立即做加载上限校验（SEC-06）：
    /// 越界即抛 [InvalidDataException] 快速拒绝，绝不进入 Argon2id 派生/分配。
    private static Argon2id.KdfParams ReadKdf(BinaryReader br)
    {
        var m = (int)br.ReadUInt32();
        var t = (int)br.ReadUInt32();
        var p = (int)br.ReadUInt32();
        VaultLimits.ValidateKdf(m, t, p);
        return new Argon2id.KdfParams(m, t, p);
    }

    public static VaultFile Load(string path)
    {
        // 整文件读入（≤16MiB，见 [VaultLimits.MaxFileSize]）：
        // 'S'（slots）尾部 HMAC 需对 raw[0 .. raw.Length-32] 精确取字节，
        // 统一走 MemoryStream 解析；对既有模式字节语义不变（流式→内存仅换来源）。
        byte[] raw;
        using (var fs = File.OpenRead(path))
        {
            if (fs.Length > VaultLimits.MaxFileSize)
                throw new InvalidDataException("vault 文件过大（可能被恶意填充），拒绝加载");
            raw = new byte[fs.Length];
            fs.ReadExactly(raw, 0, raw.Length);
        }
        using var ms = new MemoryStream(raw, writable: false);
        using var br = new BinaryReader(ms);
        if (br.ReadUInt32() != Magic) throw new InvalidDataException("vault 文件头损坏（magic 不符）");
        var version = br.ReadByte();
        var file = version switch
        {
            ModeCrypto => LoadCrypto(br),
            ModeSlots => LoadSlots(br),
            _ => throw new InvalidDataException("vault 版本不兼容"),
        };
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
            if (ctLen > VaultLimits.MaxEntryBytes || ctLen > raw.Length - br.BaseStream.Position)
                throw new InvalidDataException("vault 条目长度异常（可能被恶意构造），拒绝加载");
            file.Entries.Add(new VaultEntry
            {
                Uid = uid,
                Salt = salt,
                Nonce = nonce,
                Ciphertext = br.ReadBytes((int)ctLen),
            });
        }
        // 'S'（slots）：条目之后是尾部 32B HMAC。此处不能放进 [LoadSlots]——
        // 它在共享条目循环之前执行；循环结束后才可定位尾部并捕获 MAC 输入字节。
        if (file.Mode == VaultMode.Slots)
        {
            if (raw.Length < TrailerSize)
                throw new InvalidDataException("slots vault 缺少尾部 HMAC，拒绝加载");
            file.Trailer = raw.AsSpan(raw.Length - TrailerSize).ToArray();
            file.MacInput = raw.AsSpan(0, raw.Length - TrailerSize).ToArray();
        }
        return file;
    }

    /// 读 LEGACY（crypto）负载：key_vault 零占位 + 后端指纹。
    private static VaultFile LoadCrypto(BinaryReader br)
    {
        br.ReadBytes(3);
        return new VaultFile
        {
            KeyVault = br.ReadBytes(KeySplit.KeySize),
            Mode = VaultMode.Crypto,
            Backend = ReadBackend(br),
        };
    }

    /// 读 'S'（slots）负载头部：vaultId/createdAt/alg + 槽位表。
    /// 尾部 HMAC 由 [Load] 在共享条目循环后读取（此处不涉及条目）。
    private static VaultFile LoadSlots(BinaryReader br)
    {
        var vaultId = br.ReadBytes(VaultIdSize);
        var createdAt = br.ReadInt64();
        var alg = br.ReadByte();
        var file = new VaultFile
        {
            KeyVault = new byte[KeySplit.KeySize], // slots 无 K_vault 份额概念（零占位）
            Mode = VaultMode.Slots,
            VaultId = vaultId,
            CreatedAtMs = createdAt,
            Alg = alg,
        };
        var slotCount = br.ReadByte();
        for (var i = 0; i < slotCount; i++)
        {
            file.Slots.Add(ReadSlot(br));
        }
        return file;
    }

    /// 保存（非 slots 模式；等价 `Save(path, default)`）。
    public void Save(string path) => Save(path, default);

    /// 保存。[masterKey] 仅 'S'（slots）模式使用——尾部 HMAC-SHA256(K, header‖entries)
    /// 需要主密钥 K（其余模式忽略）。
    /// 原子写（device-bound-vault-plan §8：写临时文件 → fsync → 替换，失败保留原文件）；
    /// 替换前把当前 `path` 复制为 `path + ".bak"`（best-effort：备份失败不阻断保存）。
    public void Save(string path, ReadOnlySpan<byte> masterKey)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var tmp = path + ".tmp";
        using (var fs = File.Create(tmp))
        using (var bw = new BinaryWriter(fs))
        {
            WriteBody(bw, masterKey);
            bw.Flush();
            fs.Flush(flushToDisk: true);
        }
        // 保留上一版为 .bak（复制而非移动：`path` 始终存在，保持替换原子性；
        // 权限随源文件沿用）。失败不阻断保存（best-effort）。
        if (File.Exists(path))
        {
            try { File.Copy(path, path + ".bak", overwrite: true); }
            catch { /* 备份失败不阻断保存 */ }
        }
        File.Move(tmp, path, overwrite: true);
    }

    private void WriteBody(BinaryWriter bw, ReadOnlySpan<byte> masterKey)
    {
        if (Mode == VaultMode.Slots)
        {
            // slots：尾部 HMAC 覆盖 header‖entries，须先缓冲主体再追加 trailer。
            if (masterKey.Length != KeySplit.KeySize)
                throw new InvalidDataException("slots 模式写入缺少主密钥（无法计算尾部 HMAC）");
            byte[] body;
            using (var ms = new MemoryStream())
            {
                using (var bw2 = new BinaryWriter(ms, Encoding.UTF8, leaveOpen: true))
                {
                    WriteBodyCore(bw2);
                    bw2.Flush();
                }
                body = ms.ToArray();
            }
            bw.Write(body);
            bw.Write(ComputeSlotsMac(masterKey, body));
            return;
        }
        WriteBodyCore(bw);
    }

    private void WriteBodyCore(BinaryWriter bw)
    {
        bw.Write(Magic);
        switch (Mode)
        {
            case VaultMode.Slots:
                bw.Write(ModeSlots);
                bw.Write(VaultId!);
                bw.Write(CreatedAtMs);
                bw.Write(Alg);
                bw.Write((byte)Slots.Count);
                foreach (var slot in Slots)
                {
                    WriteSlot(bw, slot);
                }
                break;
            default:
                // LEGACY（crypto）：单因子——key_vault 为零占位，仍写后端指纹防构建形态混用
                bw.Write(ModeCrypto);
                bw.Write(new byte[3]);
                bw.Write(KeyVault);
                WriteBackend(bw);
                break;
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

    /// 写后端指纹（1B 长度 + UTF8；null/空 → 长度 0）。
    private void WriteBackend(BinaryWriter bw)
    {
        var b = Encoding.UTF8.GetBytes(Backend ?? string.Empty);
        if (b.Length > byte.MaxValue) throw new InvalidDataException("后端指纹过长");
        bw.Write((byte)b.Length);
        bw.Write(b);
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
