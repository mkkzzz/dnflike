"""文档一致性检查。

检查项：
1. markdown 相对链接是否指向存在的文件或目录
2. docs/ 根目录是否出现新文件（规范要求过程文档进 docs/reports/<工作区>/<月份>/）

用法：
    python tools/check_docs.py

退出码 0 表示无问题，1 表示发现问题。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")

SKIP_DIRS = {".git", ".godot", "temp", "godot", "__pycache__", "node_modules"}


def iter_markdown() -> list[Path]:
    out = []
    for path in REPO.rglob("*.md"):
        if SKIP_DIRS & set(path.parts):
            continue
        out.append(path)
    return sorted(out)


def check_links() -> list[str]:
    problems = []
    for md in iter_markdown():
        text = md.read_text(encoding="utf-8", errors="ignore")
        for match in LINK.finditer(text):
            raw = match.group(1).strip()
            if not raw or raw.startswith(("http://", "https://", "mailto:", "#")):
                continue
            target = raw.split("#")[0].strip()
            if not target:
                continue
            resolved = (md.parent / target).resolve()
            if not resolved.exists():
                rel = md.relative_to(REPO).as_posix()
                problems.append(f"{rel} -> {raw}")
    return problems


def check_docs_root() -> list[str]:
    docs = REPO / "docs"
    if not docs.is_dir():
        return []
    problems = []
    for child in sorted(docs.iterdir()):
        if child.is_file():
            problems.append(f"docs/{child.name}（过程文档应放入 docs/reports/<工作区>/<月份>/）")
    return problems


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    links = check_links()
    root = check_docs_root()

    if links:
        print(f"[断链] {len(links)} 处：")
        for item in links:
            print(f"  - {item}")
    if root:
        print(f"[docs 根目录违规文件] {len(root)} 处：")
        for item in root:
            print(f"  - {item}")

    if not links and not root:
        print(f"[OK] 链接与目录规范检查通过（扫描 {len(iter_markdown())} 份文档）")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
