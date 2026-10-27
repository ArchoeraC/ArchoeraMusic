#!/usr/bin/env python3
"""在 CodeQL SARIF 上传前剔除 vendored 第三方文件的结果。

背景：CodeQL 的 `paths-ignore` 对**被 src/*.c #include 的头文件**不生效
（头文件内容随源文件一起被提取），`miniaudio.h` 的 35 条整数乘法告警
因此无法靠 `.github/codeql/codeql-config.yml` 排除。这里在 SARIF 层面
按主位置路径过滤，避免 Security 页持续出现与业务代码无关的告警。

只删除 primary location 命中 VENDORED_PATHS 的结果；自研代码（src/、
kernel/*.zig、app/native/**）不过滤。用法：

    python3 .github/codeql/filter_sarif.py <sarif-dir-or-file> [...]
"""

from __future__ import annotations

import json
import pathlib
import sys

# 与 .github/codeql/codeql-config.yml 的第三方清单保持一致。
VENDORED_PATHS = (
    "app/core/audio-engine/include/miniaudio.h",
)


def _uri_matches(uri: str | None) -> bool:
    if not uri:
        return False
    # SARIF 里可能是相对路径、file:// URI 或 Windows 反斜杠路径。
    normalized = uri.replace("\\", "/").split("?", 1)[0]
    return any(normalized.endswith(path) for path in VENDORED_PATHS)


def _primary_uri(result: dict) -> str | None:
    locations = result.get("locations") or []
    if not locations:
        return None
    physical = (locations[0] or {}).get("physicalLocation") or {}
    artifact = physical.get("artifactLocation") or {}
    return artifact.get("uri")


def filter_sarif(path: pathlib.Path) -> tuple[int, int]:
    document = json.loads(path.read_text(encoding="utf-8"))
    removed = 0
    kept = 0
    for run in document.get("runs") or []:
        results = run.get("results") or []
        filtered = []
        for result in results:
            if _uri_matches(_primary_uri(result)):
                removed += 1
            else:
                filtered.append(result)
                kept += 1
        run["results"] = filtered
    if removed:
        path.write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
    return removed, kept


def iter_sarif(target: pathlib.Path):
    if target.is_dir():
        yield from sorted(target.rglob("*.sarif"))
    elif target.is_file():
        yield target


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    total_removed = 0
    for raw in argv[1:]:
        for path in iter_sarif(pathlib.Path(raw)):
            removed, kept = filter_sarif(path)
            total_removed += removed
            print(f"{path}: removed={removed} kept={kept}")
            if removed:
                print(f"  过滤 vendored 结果: {removed}（保留 {kept}）")
    print(f"filter_sarif: 共剔除 {total_removed} 条 vendored 结果")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
