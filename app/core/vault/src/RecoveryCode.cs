// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Text;

namespace Archoera.Vault;

/// 恢复码（F2）：32 字节随机恢复材料的人类可读编码——Crockford Base32（无填充）。
///
/// 展示形式：大写字母数字，每 4 个字符一组、以 `-` 分隔（32B = 52 字符 → 13 组）。
/// 输入归一化：转大写、去 `-`/空白、`I`/`L` → `1`、`O` → `0`（Crockford 易混字符），
/// 之后再按 Base32 解码。编码把 32B 视作大端 Bit 流，每 5 bit 取一个符号，末组补 0。
public static class RecoveryCode
{
    /// Crockford Base32 字母表（不含 I / L / O / U）。
    private const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    /// 每组的字符数（展示用 `-` 分隔）。
    public const int GroupSize = 4;

    /// 恢复材料的字节数（与主密钥同宽）。
    public const int ByteSize = KeySplit.KeySize;

    /// 将 32 字节编码为展示串（每 4 字符一组、`-` 分隔；无填充）。
    public static string Encode(ReadOnlySpan<byte> data)
    {
        var raw = EncodeRaw(data);
        var sb = new StringBuilder(raw.Length + raw.Length / GroupSize);
        for (var i = 0; i < raw.Length; i++)
        {
            if (i > 0 && i % GroupSize == 0) sb.Append('-');
            sb.Append(raw[i]);
        }
        return sb.ToString();
    }

    /// 归一化展示串并解码回 32 字节；长度/字符非法抛 [InvalidDataException]。
    public static byte[] Decode(string display)
    {
        var normalized = Normalize(display);
        var result = DecodeRaw(normalized);
        if (result.Length != ByteSize)
            throw new InvalidDataException($"恢复码长度异常（解码 {result.Length} 字节，应为 {ByteSize}）");
        return result;
    }

    /// 以 UTF-8 解读 [utf8] 后归一化并解码（握手负载形式）。
    public static byte[] DecodeUtf8(ReadOnlySpan<byte> utf8)
        => Decode(Encoding.UTF8.GetString(utf8));

    /// 归一化：转大写、去 `-` 与空白、`I`/`L`→`1`、`O`→`0`。
    private static string Normalize(string input)
    {
        var sb = new StringBuilder(input.Length);
        foreach (var ch in input)
        {
            var c = char.ToUpperInvariant(ch);
            switch (c)
            {
                case '-':
                case ' ':
                case '\t':
                case '\r':
                case '\n':
                    continue;
                case 'I':
                case 'L':
                    sb.Append('1');
                    break;
                case 'O':
                    sb.Append('0');
                    break;
                default:
                    sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    /// 大端 Bit 流编码（无分组填充）。
    private static string EncodeRaw(ReadOnlySpan<byte> data)
    {
        var sb = new StringBuilder((data.Length * 8 + 4) / 5);
        int buffer = 0, bits = 0;
        foreach (var b in data)
        {
            buffer = (buffer << 8) | b;
            bits += 8;
            while (bits >= 5)
            {
                bits -= 5;
                sb.Append(Alphabet[(buffer >> bits) & 0x1F]);
            }
        }
        if (bits > 0) sb.Append(Alphabet[(buffer << (5 - bits)) & 0x1F]);
        return sb.ToString();
    }

    /// 大端 Bit 流解码（尾部不足 8 bit 的填充丢弃）。
    private static byte[] DecodeRaw(string normalized)
    {
        var bytes = new List<byte>(normalized.Length * 5 / 8);
        int buffer = 0, bits = 0;
        foreach (var c in normalized)
        {
            var v = ValueOf(c);
            if (v < 0) throw new InvalidDataException($"恢复码含非法字符 '{c}'");
            buffer = (buffer << 5) | v;
            bits += 5;
            if (bits >= 8)
            {
                bits -= 8;
                bytes.Add((byte)((buffer >> bits) & 0xFF));
            }
        }
        return bytes.ToArray();
    }

    /// 归一化后字符 → 5 bit 值（无效字符返回 -1）。
    private static int ValueOf(char c)
    {
        if (c >= '0' && c <= '9') return c - '0';
        return c switch
        {
            'A' => 10, 'B' => 11, 'C' => 12, 'D' => 13, 'E' => 14, 'F' => 15,
            'G' => 16, 'H' => 17, 'J' => 18, 'K' => 19, 'M' => 20, 'N' => 21,
            'P' => 22, 'Q' => 23, 'R' => 24, 'S' => 25, 'T' => 26, 'V' => 27,
            'W' => 28, 'X' => 29, 'Y' => 30, 'Z' => 31,
            _ => -1,
        };
    }
}
