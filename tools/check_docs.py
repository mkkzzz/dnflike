"""文档一致性检查。

检查项：
1. markdown 相对链接指向存在的文件或目录
2. 反引号里写的仓库路径（docs/、art/、game/、tools/、audio/ 开头）存在
3. 表格分隔行与表头列数一致
4. 单文档行数不超过规范上限（见 docs/project/06_文档规范.md）
5. docs/ 根目录没有文件（过程文档应放入 docs/reports/<工作区>/<月份>/）

过程记录 docs/reports/ 是历史快照，不做第 2 项检查。

用法：
    python tools/check_docs.py

退出码 0 表示无问题，1 表示发现问题。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from migrate_art_layout import CATALOG, frozen, load_catalog, relocate

REPO = Path(__file__).resolve().parents[1]
ART_CATALOG = load_catalog() if CATALOG.exists() else None
LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
CODE = re.compile(r"`([^`\n]+)`")
SEP_CELL = re.compile(r"^:?-{3,}:?$")

SKIP_DIRS = {".git", ".godot", "temp", "godot", "__pycache__", "node_modules"}
PATH_ROOTS = ("docs/", "art/", "game/", "tools/", "audio/")
UNTRACKED_ROOTS = ("game/art/", "game/.godot/", "tools/godot/", "temp/")
PLACEHOLDER = set("<>*{}$|")
FROZEN = ("docs/reports/",)

LIMITS = [
    ("README.md", 60),
    ("AGENTS.md", 120),
    ("docs/project/", 150),
    ("docs/design/", 300),
]


def iter_markdown() -> list[Path]:
    return sorted(p for p in REPO.rglob("*.md") if not SKIP_DIRS & set(p.parts))


def rel(path: Path) -> str:
    return path.relative_to(REPO).as_posix()


def target_exists(md: Path, target: Path) -> bool:
    target = target.resolve()
    if target.exists():
        return True
    if not ART_CATALOG or not frozen(rel(md), ART_CATALOG):
        return False
    try:
        old = target.relative_to(REPO).as_posix()
    except ValueError:
        return False
    new = relocate(old, ART_CATALOG["migration"]["moves"])
    return new != old and (REPO / new).exists()


def check_links(md: Path, text: str) -> list[str]:
    problems = []
    for match in LINK.finditer(text):
        raw = match.group(1).strip()
        if not raw or raw.startswith(("http://", "https://", "mailto:", "#")):
            continue
        target = raw.split("#")[0].strip()
        if target and not target_exists(md, md.parent / target):
            problems.append(f"{rel(md)} -> {raw}")
    return problems


def check_code_paths(md: Path, text: str) -> list[str]:
    if rel(md).startswith(FROZEN):
        return []
    problems = []
    for match in CODE.finditer(text):
        token = match.group(1).strip()
        if not token.startswith(PATH_ROOTS) or token.startswith(UNTRACKED_ROOTS):
            continue
        if " " in token or PLACEHOLDER & set(token):
            continue
        if not target_exists(md, REPO / token):
            problems.append(f"{rel(md)} -> `{token}`")
    return problems


def cells(line: str) -> list[str]:
    body = re.sub(r"`[^`]*`", "``", line.strip())
    return body.strip("|").split("|")


def check_tables(md: Path, lines: list[str]) -> list[str]:
    problems = []
    in_fence = False
    for i, line in enumerate(lines):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
        if in_fence or i == 0:
            continue
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        sep = cells(stripped)
        if not all(SEP_CELL.match(c.strip()) for c in sep if c.strip()):
            continue
        header = lines[i - 1].strip()
        if header.startswith("|") and len(cells(header)) != len(sep):
            problems.append(f"{rel(md)}:{i + 1} 表头 {len(cells(header))} 列，分隔行 {len(sep)} 列")
    return problems


def check_size(md: Path, lines: list[str]) -> list[str]:
    path = rel(md)
    for prefix, limit in LIMITS:
        if path == prefix or (prefix.endswith("/") and path.startswith(prefix)):
            if len(lines) > limit:
                return [f"{path} 共 {len(lines)} 行，超过上限 {limit} 行（需拆分）"]
            return []
    return []


def check_docs_root() -> list[str]:
    docs = REPO / "docs"
    if not docs.is_dir():
        return []
    return [f"docs/{c.name}（应放入 docs/reports/<工作区>/<月份>/）" for c in sorted(docs.iterdir()) if c.is_file()]


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    found: dict[str, list[str]] = {"断链": [], "路径不存在": [], "表格列数不一致": [], "超出体积上限": []}
    files = iter_markdown()
    for md in files:
        text = md.read_text(encoding="utf-8", errors="ignore")
        lines = text.splitlines()
        found["断链"] += check_links(md, text)
        found["路径不存在"] += check_code_paths(md, text)
        found["表格列数不一致"] += check_tables(md, lines)
        found["超出体积上限"] += check_size(md, lines)
    found["docs 根目录违规文件"] = check_docs_root()

    total = 0
    for title, items in found.items():
        if items:
            total += len(items)
            print(f"[{title}] {len(items)} 处：")
            for item in items:
                print(f"  - {item}")

    if total == 0:
        print(f"[OK] 文档检查通过（扫描 {len(files)} 份文档）")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
