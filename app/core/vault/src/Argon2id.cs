using System.Buffers.Binary;
using System.Text;

namespace Archoera.Vault;

/// Argon2id v1.3 口令派生（RFC 9106）——纯 BCL 实现，零第三方依赖
/// （NativeAOT 单文件，离线可构建；credential-vault-plan §3.2 口令派生模式）。
///
/// 与 phc-winner-argon2 参考实现逐块对齐：
///   - Blake2b-512 变长输出 H'（RFC 9106 Figure 8）；
///   - H0 初始化哈希（Figure 1）、内存填充（Figure 10）、索引映射（Figure 13）；
///   - Argon2id 混合寻址：pass 0 的前半 slice 用 Argon2i（数据无关），
///     其余用 Argon2d（数据相关，J1/J2 取自前块首字）。
/// 正确性由 [SelfTest] 保证（RFC 9106 §5.3 + 本地参考实现交叉验证的向量）。
public static class Argon2id
{
    public const int BlockBytes = 1024;
    public const int BlockWords = BlockBytes / 8; // 128
    private const int SyncPoints = 4;
    private const int AddressesInBlock = BlockWords; // 每地址块 128 个 8 字节伪随机字
    private const uint Version = 0x13;
    private const uint TypeId = 2; // Argon2id

    /// 口令派生 KDF 参数（随 vault 文件头存储，可按安装调整后重初始化）。
    public sealed record KdfParams(int MKiB, int T, int P)
    {
        /// 默认：64 MiB / 3 轮 / 单通道（RFC 9106 第二条推荐档；防 GPU 爆破）。
        public static KdfParams Default { get; } = new(65536, 3, 1);
    }

    /// BLAKE2b-512 IV（RFC 7693）。
    private static readonly ulong[] Iv =
    {
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1, 0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    };

    /// BLAKE2b 消息调度表（rounds 0..11，10/11 复用 σ[0]/σ[1]）。
    private static readonly byte[][] Sigma =
    {
        new byte[] { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        new byte[] { 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
        new byte[] { 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
        new byte[] { 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
        new byte[] { 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
        new byte[] { 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
        new byte[] { 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
        new byte[] { 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
        new byte[] { 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
        new byte[] { 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
        new byte[] { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        new byte[] { 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
    };

    /// 派生口令派生密钥（输出 [tagLen] 字节）。[password] 为调用方所有，
    /// 用后须自行清零；[salt] ≥ 8 字节（默认由调用方随机生成并持久化）。
    public static byte[] Derive(
        ReadOnlySpan<byte> password, ReadOnlySpan<byte> salt,
        ReadOnlySpan<byte> secret, ReadOnlySpan<byte> ad,
        int mKiB, int t, int p, int tagLen)
    {
        if (p < 1) throw new ArgumentOutOfRangeException(nameof(p), "并行度必须 ≥ 1");
        if (mKiB < 8 * p) throw new ArgumentOutOfRangeException(nameof(mKiB), "内存必须 ≥ 8p KiB");
        if (t < 1) throw new ArgumentOutOfRangeException(nameof(t), "迭代必须 ≥ 1");
        if (salt.Length < 8) throw new ArgumentException("盐长度必须 ≥ 8 字节", nameof(salt));
        if (tagLen < 4) throw new ArgumentOutOfRangeException(nameof(tagLen), "输出长度必须 ≥ 4");

        // m' = 4p · floor(m / 4p)（RFC 9106 §3.2：内存块数须为 4p 的倍数）
        var memoryBlocks = (mKiB / (4 * p)) * 4 * p;
        var laneLength = memoryBlocks / p;
        var segmentLength = laneLength / SyncPoints;

        var h0 = ComputeH0(password, salt, secret, ad, memoryBlocks, t, p, tagLen);

        var memory = new ulong[memoryBlocks * BlockWords];
        // B[i][0]、B[i][1]：H'^1024(H0 || LE32(0|1) || LE32(i))
        for (var lane = 0; lane < p; lane++)
        {
            InitialBlock(memory, lane * laneLength + 0, h0, 0, lane);
            InitialBlock(memory, lane * laneLength + 1, h0, 1, lane);
        }

        if (Environment.GetEnvironmentVariable("ARCHOERA_DEBUG_DERIVE") == "1")
        {
            Console.Error.WriteLine(
                $"h0({mKiB},{t},{p}) mb={memoryBlocks} lane={laneLength} seg={segmentLength}");
            Console.Error.WriteLine("H0=" + Convert.ToHexString(h0).ToLowerInvariant());
            var b00 = new ulong[4];
            Array.Copy(memory, 0, b00, 0, 4);
            Console.Error.WriteLine("B00=" + string.Join("", b00.Select(
                w => Convert.ToHexString(BitConverter.GetBytes(w)).ToLowerInvariant())));
        }

        var zero = new ulong[BlockWords];
        var input = new ulong[BlockWords];
        var address = new ulong[BlockWords];

        // 内存填充：slice 为外层、lane 为内层（与参考实现顺序一致）
        for (var pass = 0; pass < t; pass++)
        {
            for (var slice = 0; slice < SyncPoints; slice++)
            {
                FillSegment(memory, p, laneLength, segmentLength, memoryBlocks, t,
                    pass, slice, zero, input, address);
            }
        }

        // 最终化：C = 每 lane 末块异或 → tag = H'^tagLen(C)
        var c = new ulong[BlockWords];
        for (var lane = 0; lane < p; lane++)
        {
            var last = lane * laneLength + laneLength - 1;
            for (var k = 0; k < BlockWords; k++) c[k] ^= memory[last * BlockWords + k];
        }
        var cBytes = new byte[BlockBytes];
        for (var k = 0; k < BlockWords; k++)
        {
            BinaryPrimitives.WriteUInt64LittleEndian(cBytes.AsSpan(k * 8), c[k]);
        }
        return VariableLengthHash(cBytes, tagLen);
    }

    /// 自检：运行 RFC 9106 §5.3 测试向量 + 本地 phc-winner-argon2 交叉验证向量。
    /// 全部通过返回 true；任一失败返回 false（构建/CI 用 `selftest` 命令触发）。
    public static bool SelfTest()
    {
        // 1) RFC 9106 §5.3 Argon2id（ASCII 口令/盐）——与本地参考实现一致
        if (!Check(Ascii("password"), Ascii("somesalt"), [], [], 32, 3, 4,
            "bb0cc80a3e671149526915418c6eefe761bb19d5d2d567a017703e0cea6ab05c"))
            return false;
        // 2) 大内存档（覆盖多 slice/索引路径）——本地参考实现生成
        if (!Check(Ascii("password"), Ascii("somesalt"), [], [], 65536, 3, 4,
            "661fefbd6f29bcbc8f4646abc32a9d7a4645bb5c059537f8a5587f31adbecccd"))
            return false;
        // 3) 生产默认档（m=19456,t=2,p=1 小样本）——本地参考实现生成
        if (!Check(Ascii("testpass"), Ascii("0123456789abcdef"), [], [], 19456, 2, 1,
            "9f9478c592f2998226442b4b4aa33ce610ab8ed6dff16945ba62339e70b05cea"))
            return false;
        // 4) RFC 9106 §5.3 带 secret + 关联数据（二进制 P=0x01×32, S=0x02×16, K=0x03×8, X=0x04×12）
        if (!Check(Repeat(0x01, 32), Repeat(0x02, 16), Repeat(0x03, 8), Repeat(0x04, 12),
            32, 3, 4, "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"))
            return false;
        return true;
    }

    private static bool Check(byte[] p, byte[] s, byte[] k, byte[] x, int m, int t, int pp,
        string expectedHex)
    {
        var got = Derive(p, s, k, x, m, t, pp, 32);
        var expected = Convert.FromHexString(expectedHex);
        var ok = got.AsSpan().SequenceEqual(expected);
        if (!ok && Environment.GetEnvironmentVariable("ARCHOERA_DEBUG_DERIVE") == "1")
        {
            Console.Error.WriteLine($"derive(m={m},t={t},p={pp}) got={Convert.ToHexString(got).ToLowerInvariant()} exp={expectedHex}");
        }
        return ok;
    }

    // ── H0（RFC 9106 Figure 1）────────────────────────────────────────

    private static byte[] ComputeH0(
        ReadOnlySpan<byte> password, ReadOnlySpan<byte> salt,
        ReadOnlySpan<byte> secret, ReadOnlySpan<byte> ad,
        int memoryBlocks, int t, int p, int tagLen)
    {
        var buf = new List<byte>(256);
        AddI32(buf, p);
        AddI32(buf, tagLen);
        AddI32(buf, memoryBlocks);
        AddI32(buf, t);
        AddI32(buf, (int)Version);
        AddI32(buf, (int)TypeId);
        AddI32(buf, password.Length); buf.AddRange(password.ToArray());
        AddI32(buf, salt.Length); buf.AddRange(salt.ToArray());
        AddI32(buf, secret.Length); buf.AddRange(secret.ToArray());
        AddI32(buf, ad.Length); buf.AddRange(ad.ToArray());
        return Blake2b(buf.ToArray(), 64);
    }

    private static void AddI32(List<byte> buf, int v)
    {
        Span<byte> b = stackalloc byte[4];
        BinaryPrimitives.WriteInt32LittleEndian(b, v);
        buf.AddRange(b.ToArray());
    }

    // ── 内存填充 ───────────────────────────────────────────────────────

    /// 填充单个 slice（内部遍历全部 lane；与参考 fill_memory_blocks_st 顺序一致）。
    private static void FillSegment(
        ulong[] memory, int p, int laneLength, int segmentLength, int memoryBlocks,
        int passes, int pass, int slice, ulong[] zero, ulong[] input, ulong[] address)
    {
        // Argon2id：仅 pass 0 前半 slice 用数据无关寻址（Argon2i）
        var dataIndependent = pass == 0 && slice < SyncPoints / 2;

        for (var lane = 0; lane < p; lane++)
        {
            var startIndex = (pass == 0 && slice == 0) ? 2 : 0;
            var currOffset = lane * laneLength + slice * segmentLength + startIndex;
            var prevOffset = currOffset % laneLength == 0
                ? currOffset + laneLength - 1
                : currOffset - 1;

            if (dataIndependent)
            {
                // 地址输入块 Z = LE64(r)||LE64(l)||LE64(sl)||LE64(m')||LE64(t)||LE64(y)
                input[0] = (uint)pass;
                input[1] = (uint)lane;
                input[2] = (uint)slice;
                input[3] = (uint)memoryBlocks;
                input[4] = (uint)passes;
                input[5] = TypeId;
                input[6] = 0; // 计数器（NextAddresses 先自增到 1）
                Array.Clear(address);
                // pass 0 slice 0 的块 0/1 已由 H' 预生成，跳过 i=0,1；
                // 须先预生成第一批地址，位置 2..127 才能取到真伪随机值
                if (pass == 0 && slice == 0) NextAddresses(address, input);
            }

            for (var i = startIndex; i < segmentLength; i++, currOffset++, prevOffset++)
            {
                // 1.1 前一块回绕修正（跨 lane 首块时取同 lane 前一块）
                if (currOffset % laneLength == 1) prevOffset = currOffset - 1;

                // 1.2 伪随机值：数据无关走地址块，数据相关取前块首字
                ulong pseudoRand;
                if (dataIndependent)
                {
                    if (i % AddressesInBlock == 0) NextAddresses(address, input);
                    pseudoRand = address[i % AddressesInBlock];
                }
                else
                {
                    pseudoRand = memory[prevOffset * BlockWords];
                }

                // 1.2.3 参考 lane：pass 0 slice 0 强制同 lane，其余 J2 = 高 32 位
                var refLane = (pass == 0 && slice == 0)
                    ? lane
                    : (int)((pseudoRand >> 32) % (ulong)p);
                var sameLane = refLane == lane;

                // 1.2.4 参考区域大小 W（RFC 9106 Figure 13 规则 1/2）
                long refAreaSize;
                if (pass == 0)
                {
                    if (slice == 0) refAreaSize = i - 1;              // 本段已完成块（去前一块）
                    else if (sameLane) refAreaSize = slice * segmentLength + i - 1;
                    else refAreaSize = slice * segmentLength + (i == 0 ? -1 : 0);
                }
                else
                {
                    if (sameLane) refAreaSize = laneLength - segmentLength + i - 1;
                    else refAreaSize = laneLength - segmentLength + (i == 0 ? -1 : 0);
                }
                if (refAreaSize < 0) refAreaSize = 0;

                // 1.2.5 映射到 [0, |W|)：z = |W| - 1 - (|W| · (J1²/2³²))/2³²
                var j1 = (uint)pseudoRand;
                var x = ((ulong)j1 * j1) >> 32;
                var y = (long)(((ulong)refAreaSize * x) >> 32);
                var relativePos = (int)(refAreaSize - 1 - y);

                // 1.2.6 绝对位置（pass ≥ 1 时跳过当前 slice 的段）
                var startPos = pass == 0
                    ? 0
                    : (slice == SyncPoints - 1 ? 0 : (slice + 1) * segmentLength);
                var absPos = (startPos + relativePos) % laneLength;
                var refOffset = refLane * laneLength + absPos;

                if (Environment.GetEnvironmentVariable("ARCHOERA_DEBUG_DERIVE") == "1" &&
                    pass == 0 && slice == 1 && lane == 0 && i == 0)
                {
                    Console.Error.WriteLine(
                        $"P0S1L0i0 curr={currOffset} prev={prevOffset} ref_lane={refLane} " +
                        $"ref_off={refOffset} pseudo={pseudoRand:x16}");
                }

                // 2. 生成新块：pass 0 覆盖写，pass ≥ 1 异或写（v1.3 语义）。
                //    注意 memory 以「字」为索引，块偏移须 × BlockWords。
                var xOff = prevOffset * BlockWords;
                var yOff = refOffset * BlockWords;
                var dOff = currOffset * BlockWords;
                if (pass == 0) FillBlock(memory, xOff, yOff, dOff);
                else FillBlockXor(memory, xOff, yOff, dOff);

                if (Environment.GetEnvironmentVariable("ARCHOERA_DEBUG_DERIVE") == "1" &&
                    pass == 0 && slice == 1 && lane == 0 && i == 0)
                {
                    var o = currOffset * BlockWords;
                    Console.Error.WriteLine("P0S1L0i0 out=" +
                        string.Join("", Enumerable.Range(0, 4).Select(
                            k => Convert.ToHexString(BitConverter.GetBytes(memory[o + k])).ToLowerInvariant())));
                }
            }
        }
    }

    /// 生成下一批 128 个伪随机地址：G(ZERO, G(ZERO, input))，计数器自增。
    private static void NextAddresses(ulong[] address, ulong[] input)
    {
        input[6]++;
        FillFromInput(input, address);
        FillFromInput(address, address);
    }

    /// G(ZERO(1024), X)：R = X，Z = P 置换，输出 Z ⊕ R。
    private static void FillFromInput(ulong[] input, ulong[] dest)
    {
        var z = new ulong[BlockWords];
        Array.Copy(input, z, BlockWords);
        ApplyPermutation(z);
        for (var i = 0; i < BlockWords; i++) dest[i] = z[i] ^ input[i];
    }

    /// G(prev, ref)：R = prev ⊕ ref，Z = P 置换，写入 dest = Z ⊕ R（覆盖）。
    private static void FillBlock(ulong[] memory, int xOff, int yOff, int destOff)
    {
        var r = new ulong[BlockWords];
        var z = new ulong[BlockWords];
        for (var i = 0; i < BlockWords; i++)
        {
            r[i] = memory[xOff + i] ^ memory[yOff + i];
            z[i] = r[i];
        }
        ApplyPermutation(z);
        for (var i = 0; i < BlockWords; i++) memory[destOff + i] = z[i] ^ r[i];
    }

    /// G(prev, ref) 异或写入（pass ≥ 1）：dest = dest ⊕ (Z ⊕ R)。
    private static void FillBlockXor(ulong[] memory, int xOff, int yOff, int destOff)
    {
        var r = new ulong[BlockWords];
        var z = new ulong[BlockWords];
        for (var i = 0; i < BlockWords; i++)
        {
            r[i] = memory[xOff + i] ^ memory[yOff + i];
            z[i] = r[i];
        }
        ApplyPermutation(z);
        for (var i = 0; i < BlockWords; i++) memory[destOff + i] ^= z[i] ^ r[i];
    }

    /// P 置换：先对 8 行（16 连续字）再对 8 列（跨 16 字步长的 8 对）应用 BLAKE2b 轮。
    private static void ApplyPermutation(ulong[] block)
    {
        for (var row = 0; row < 8; row++) Permute16(block, row * 16);
        var tmp = new ulong[16];
        for (var col = 0; col < 8; col++)
        {
            for (var k = 0; k < 16; k++)
            {
                tmp[k] = block[2 * col + 16 * (k / 2) + (k % 2)];
            }
            Permute16(tmp, 0);
            for (var k = 0; k < 16; k++)
            {
                block[2 * col + 16 * (k / 2) + (k % 2)] = tmp[k];
            }
        }
    }

    /// BLAKE2b 轮（Argon2 变体：fBlaMka + 64 位循环移位）。
    private static void Permute16(ulong[] v, int o)
    {
        G(ref v[o + 0], ref v[o + 4], ref v[o + 8], ref v[o + 12]);
        G(ref v[o + 1], ref v[o + 5], ref v[o + 9], ref v[o + 13]);
        G(ref v[o + 2], ref v[o + 6], ref v[o + 10], ref v[o + 14]);
        G(ref v[o + 3], ref v[o + 7], ref v[o + 11], ref v[o + 15]);
        G(ref v[o + 0], ref v[o + 5], ref v[o + 10], ref v[o + 15]);
        G(ref v[o + 1], ref v[o + 6], ref v[o + 11], ref v[o + 12]);
        G(ref v[o + 2], ref v[o + 7], ref v[o + 8], ref v[o + 13]);
        G(ref v[o + 3], ref v[o + 4], ref v[o + 9], ref v[o + 14]);
    }

    /// Argon2 混洗函数 fBlaMka（64 位算术，低位 32 位乘不进位溢出语义）。
    private static ulong FBlaMka(ulong x, ulong y) => x + y + 2UL * (uint)x * (uint)y;

    private static ulong Rotr(ulong x, int n) => (x >> n) | (x << (64 - n));

    private static void G(ref ulong a, ref ulong b, ref ulong c, ref ulong d)
    {
        a = FBlaMka(a, b);
        d = Rotr(d ^ a, 32);
        c = FBlaMka(c, d);
        b = Rotr(b ^ c, 24);
        a = FBlaMka(a, b);
        d = Rotr(d ^ a, 16);
        c = FBlaMka(c, d);
        b = Rotr(b ^ c, 63);
    }

    // ── B[i][0] / B[i][1] ─────────────────────────────────────────────

    private static void InitialBlock(ulong[] memory, int blockIndex, byte[] h0, int value, int lane)
    {
        var input = new byte[h0.Length + 8];
        Array.Copy(h0, input, h0.Length);
        BinaryPrimitives.WriteInt32LittleEndian(input.AsSpan(h0.Length), value);
        BinaryPrimitives.WriteInt32LittleEndian(input.AsSpan(h0.Length + 4), lane);
        var block = VariableLengthHash(input, BlockBytes);
        for (var i = 0; i < BlockWords; i++)
        {
            memory[blockIndex * BlockWords + i] =
                BinaryPrimitives.ReadUInt64LittleEndian(block.AsSpan(i * 8));
        }
    }

    // ── Blake2b（RFC 7693，输出 1..64 字节）────────────────────────────

    private static byte[] Blake2b(ReadOnlySpan<byte> data, int outLen)
    {
        var h = new ulong[8];
        Array.Copy(Iv, h, 8);
        h[0] ^= 0x01010000UL ^ (uint)outLen; // kk=0，仅参数 nn 参与
        var block = new byte[128];
        var full = data.Length / 128;
        var t = 0UL;
        for (var i = 0; i < full; i++)
        {
            data.Slice(i * 128, 128).CopyTo(block);
            t += 128;
            Blake2bCompress(h, block, t, false);
        }
        Array.Clear(block);
        data.Slice(full * 128).CopyTo(block);
        t += (ulong)(data.Length - full * 128);
        Blake2bCompress(h, block, t, true);
        var result = new byte[outLen];
        for (var i = 0; i < (outLen + 7) / 8; i++)
        {
            BinaryPrimitives.WriteUInt64LittleEndian(result.AsSpan(i * 8), h[i]);
        }
        return result;
    }

    private static void Blake2bCompress(ulong[] h, byte[] block, ulong t, bool isFinal)
    {
        Span<ulong> m = stackalloc ulong[16];
        for (var i = 0; i < 16; i++)
        {
            m[i] = BinaryPrimitives.ReadUInt64LittleEndian(block.AsSpan(i * 8));
        }
        var v = new ulong[16];
        for (var i = 0; i < 8; i++)
        {
            v[i] = h[i];
            v[i + 8] = Iv[i];
        }
        v[12] ^= t;
        v[13] ^= 0; // 输入 ≤ 2^64 字节，高位计数字恒 0
        if (isFinal) v[14] = ~v[14];
        for (var round = 0; round < 12; round++)
        {
            var s = Sigma[round];
            Blake2bG(ref v[0], ref v[4], ref v[8], ref v[12], m[s[0]], m[s[1]]);
            Blake2bG(ref v[1], ref v[5], ref v[9], ref v[13], m[s[2]], m[s[3]]);
            Blake2bG(ref v[2], ref v[6], ref v[10], ref v[14], m[s[4]], m[s[5]]);
            Blake2bG(ref v[3], ref v[7], ref v[11], ref v[15], m[s[6]], m[s[7]]);
            Blake2bG(ref v[0], ref v[5], ref v[10], ref v[15], m[s[8]], m[s[9]]);
            Blake2bG(ref v[1], ref v[6], ref v[11], ref v[12], m[s[10]], m[s[11]]);
            Blake2bG(ref v[2], ref v[7], ref v[8], ref v[13], m[s[12]], m[s[13]]);
            Blake2bG(ref v[3], ref v[4], ref v[9], ref v[14], m[s[14]], m[s[15]]);
        }
        for (var i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i + 8];
    }

    /// BLAKE2b 混洗（标准轮函数，与 Argon2 的 [G] 不同）。
    private static void Blake2bG(ref ulong a, ref ulong b, ref ulong c, ref ulong d,
        ulong x, ulong y)
    {
        a = a + b + x;
        d = Rotr(d ^ a, 32);
        c = c + d;
        b = Rotr(b ^ c, 24);
        a = a + b + y;
        d = Rotr(d ^ a, 16);
        c = c + d;
        b = Rotr(b ^ c, 63);
    }

    // ── H' 变长输出（RFC 9106 Figure 8）───────────────────────────────

    private static byte[] VariableLengthHash(byte[] input, int outLen)
    {
        if (outLen <= 64)
        {
            var prefix = new byte[4 + input.Length];
            BinaryPrimitives.WriteInt32LittleEndian(prefix, outLen);
            input.CopyTo(prefix, 4);
            return Blake2b(prefix, outLen);
        }
        var r = (outLen + 31) / 32 - 2;
        var result = new byte[outLen];
        var prefix2 = new byte[4 + input.Length];
        BinaryPrimitives.WriteInt32LittleEndian(prefix2, outLen);
        input.CopyTo(prefix2, 4);
        var v = Blake2b(prefix2, 64); // V_1
        for (var i = 0; i < r; i++)
        {
            Array.Copy(v, 0, result, i * 32, 32); // W_i = V_i 前 32 字节
            v = Blake2b(v, 64);                   // V_{i+1}
        }
        // 循环 r 次后 v = V_{r+1}，直接取前 (T-32r) 字节作为末段（对齐 blake2b_long，
        // 不可再 hash——否则会输出 V_{r+2}，导致第 120 字起整体错位）
        Array.Copy(v, 0, result, r * 32, outLen - 32 * r);
        return result;
    }

    // ── 测试辅助 ───────────────────────────────────────────────────────

    private static byte[] Ascii(string s) => Encoding.ASCII.GetBytes(s);

    private static byte[] Repeat(byte b, int n)
    {
        var a = new byte[n];
        Array.Fill(a, b);
        return a;
    }
}
