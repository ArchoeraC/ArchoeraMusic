#!/usr/bin/env python3
# ArchoeraMusic UI
# Copyright (C) 2026 Archoera && BetaStudio2
# SPDX-License-Identifier: AGPL-3.0-or-later
"""发布 SBOM 归一化（CycloneDX JSON，配合 `gen_sbom.sh` 使用）。

syft 直接扫「产物 + 锁文件」得到的原始清单有三处不适合直接发布：

1. **主体是文件/目录**：目录扫描会把 `metadata.component.type` 记成 `file`，
   而发布物的主体应当是**应用**（ArchoeraMusic <版本>）；
2. **文件条目噪音**：目录里的普通文件会被记成 `type: file` 组件（绝对路径 +
   码值），它们不是依赖；发布资产的字节校验由 `SHA256SUMS` / `.sig1` 负责；
3. **重复**：同一 crate / NuGet 包会出现在多个锁文件里（5 份 `Cargo.lock`、
   scanner 与 indexer 各一份 NuGet 锁），产生同 purl 的多条组件。

用法：sbom_normalize.py <syft 原始 JSON> <输出 JSON> <版本号>
"""

import json
import sys
from collections import OrderedDict


def _identity(component: dict) -> str:
    """组件身份：优先 purl（跨锁文件 / 跨平台同源），否则退回「类型+名称+版本」。"""
    purl = component.get("purl")
    if purl:
        return purl
    return "|".join(
        str(component.get(field) or "") for field in ("type", "name", "version")
    )


def normalize(raw_path: str, out_path: str, version: str) -> None:
    with open(raw_path, encoding="utf-8") as handle:
        doc = json.load(handle)

    # 1) 去掉 `type: file` 的普通文件条目（不是依赖，且带绝对路径）。
    components = [
        c for c in (doc.get("components") or []) if c.get("type") != "file"
    ]

    # 2) 去重：同身份只留第一条（含其 properties / externalReferences）；
    #    被合并者的依赖边稍后并入 canonical 组件（记下别名）。
    canonical: "OrderedDict[str, dict]" = OrderedDict()
    alias: dict[str, str] = {}
    for component in components:
        identity = _identity(component)
        ref = component.get("bom-ref")
        if identity in canonical:
            if ref:
                alias[ref] = canonical[identity]["bom-ref"]
            continue
        canonical[identity] = component
    kept = list(canonical.values())
    kept_refs = {c.get("bom-ref") for c in kept if c.get("bom-ref")}

    # 3) 依赖图：把被合并组件的边并到 canonical 组件，丢弃指向已删组件的边。
    merged: "OrderedDict[str, list[str]]" = OrderedDict()
    for edge in doc.get("dependencies") or []:
        ref = alias.get(edge.get("ref"), edge.get("ref"))
        if ref not in kept_refs:
            continue
        bucket = merged.setdefault(ref, [])
        for dep in edge.get("dependsOn") or []:
            resolved = alias.get(dep, dep)
            if resolved in kept_refs and resolved not in bucket:
                bucket.append(resolved)
    dependencies = [
        {"ref": ref, "dependsOn": sorted(deps)} for ref, deps in merged.items()
    ]

    # 4) 主体：应用（ArchoeraMusic <版本>），而不是「被扫描的文件/目录」。
    metadata = doc.setdefault("metadata", {})
    root = metadata.setdefault("component", {})
    root["type"] = "application"
    root["name"] = "ArchoeraMusic"
    root["version"] = version
    # 根节点展开为「包含全部组件」，便于 Dependency-Track 等工具按项目展开。
    root_ref = root.get("bom-ref")
    if root_ref:
        dependencies.insert(
            0, {"ref": root_ref, "dependsOn": sorted(kept_refs)}
        )

    doc["components"] = kept
    doc["dependencies"] = dependencies

    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, ensure_ascii=False, indent=1)
        handle.write("\n")

    # 摘要（CI 日志可读）：按 purl 生态族统计组件数。
    families: dict[str, int] = {}
    for component in kept:
        purl = component.get("purl") or ""
        family = purl.split("/", 1)[0].removeprefix("pkg:") if purl else "unknown"
        families[family] = families.get(family, 0) + 1
    summary = " ".join(f"{k}={v}" for k, v in sorted(families.items()))
    print(f"[sbom] 组件 {len(kept)}（{summary}）；依赖边 {len(dependencies)}")


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    normalize(argv[1], argv[2], argv[3])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
