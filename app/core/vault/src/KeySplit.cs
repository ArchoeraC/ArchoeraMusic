// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

namespace Archoera.Vault;

/// 主密钥 / 份额材料的公共长度定义。
///
/// 主密钥 K（LEGACY crypto 的整体密钥；'S' slots 槽位封装的主密钥）与授权侧
/// 份额材料统一为 32 字节；本类集中该常量，供 vault 头部、槽位与份额编码共享。
public static class KeySplit
{
    public const int KeySize = 32;
}
