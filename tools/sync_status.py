"""开工同步：告诉当前工作区"别人做了什么、什么在等我"。

用法：
    python tools/sync_status.py --init ws1   首次使用，登记本 clone 是哪个工作区
    python tools/sync_status.py              日常开工：拉取远程并汇总，记住本次看到的位置
    python tools/sync_status.py --peek       只看不记（下次仍从上次位置开始列）
    python tools/sync_status.py --no-fetch   不联网，只用本地已有的远程引用
    python tools/sync_status.py --no-proxy   忽略系统代理，强制直连（默认自动沿用系统代理）

本地标识存在仓库根目录 .workspace（不入库），内容为 id=ws<N> 与 last_seen=<远程 SHA>。
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
WS_FILE = REPO / ".workspace"
PROJECT = REPO / "docs" / "project"
STATUS_DIR = PROJECT / "status"
TODO = PROJECT / "02_待办.md"
REGISTRY = PROJECT / "03_工作区登记.md"
HUB_PATHS = ["docs/project/", "AGENTS.md", ".gitattributes", ".gitignore"]
REMOTE = "origin/main"
STALE_DAYS = 7
ACTIVE_STATES = {"进行中", "等待"}
WS_ID = re.compile(r"^ws\d+$")
TAG = re.compile(r"^\[(ws\d+)\]\s*")
SEP_CELL = re.compile(r"^:?-{3,}:?$")
GODOT = REPO / "tools" / "godot" / "Godot_v4.7.2-stable_win64_console.exe"


def find_git() -> str:
    found = shutil.which("git")
    if found:
        return found
    for candidate in (r"C:\Program Files\Git\bin\git.exe", r"C:\Program Files\Git\cmd\git.exe"):
        if Path(candidate).exists():
            return candidate
    sys.exit("找不到 git：请安装 Git for Windows 或将其加入 PATH")


GIT = find_git()
PROXY_ENV_KEYS = ("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY")
NO_PROXY = False
_SYSTEM_PROXY: str | None = None


def system_proxy() -> str:
    """读 Windows 系统代理（Internet 选项）。返回 '' 表示没有可用代理。

    浏览器、GitHub Desktop 等走 WinINET 代理，而 git 只认环境变量 /
    http.proxy，直连 GitHub 常常只有几十 KiB/s。这里自动沿用系统代理，
    不改任何 git 配置；macOS / Linux 或读不到设置时按直连处理。
    """
    global _SYSTEM_PROXY
    if _SYSTEM_PROXY is not None:
        return _SYSTEM_PROXY
    _SYSTEM_PROXY = ""
    if not NO_PROXY and os.name == "nt":
        try:
            import winreg

            with winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Internet Settings",
            ) as key:
                enabled, _ = winreg.QueryValueEx(key, "ProxyEnable")
                server, _ = winreg.QueryValueEx(key, "ProxyServer")
            if enabled and server:
                for part in str(server).split(";"):
                    scheme, _, addr = part.partition("=")
                    if scheme.strip().lower() in ("http", "https"):
                        _SYSTEM_PROXY = f"http://{addr.strip()}"
                        break
                    if not _:
                        _SYSTEM_PROXY = f"http://{part.strip()}"
                        break
        except (ImportError, OSError, ValueError):
            pass
    return _SYSTEM_PROXY


def git_env() -> dict[str, str]:
    env = dict(os.environ)
    if any(env.get(k) for k in PROXY_ENV_KEYS):
        return env
    proxy = system_proxy()
    if proxy:
        env["HTTPS_PROXY"] = env["HTTP_PROXY"] = proxy
    return env


def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(
        [GIT, "-c", "core.quotepath=false", *args],
        cwd=REPO, capture_output=True, text=True, encoding="utf-8", errors="replace",
        env=git_env(),
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} 失败")
    return result.stdout.rstrip()


def load_ws() -> dict[str, str]:
    if not WS_FILE.exists():
        return {}
    data = {}
    for line in WS_FILE.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            data[key.strip()] = value.strip()
    return data


def save_ws(data: dict[str, str]) -> None:
    WS_FILE.write_text("".join(f"{k}={v}\n" for k, v in data.items()), encoding="utf-8")


def split_row(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def read_tables(path: Path) -> list[tuple[str, dict[str, str]]]:
    """返回 [(所在小节标题, {表头: 单元格})]，跳过占位行。"""
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8").splitlines()
    rows: list[tuple[str, dict[str, str]]] = []
    section, headers = "", None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("#"):
            section, headers = stripped.lstrip("#").strip(), None
            continue
        if not stripped.startswith("|"):
            headers = None
            continue
        cells = split_row(stripped)
        if all(SEP_CELL.match(c) for c in cells if c):
            continue
        following = lines[i + 1].strip() if i + 1 < len(lines) else ""
        if following.startswith("|") and all(SEP_CELL.match(c) for c in split_row(following) if c):
            headers = cells
            continue
        if headers is None or not cells or cells[0] in ("—", "-", ""):
            continue
        rows.append((section, dict(zip(headers, cells))))
    return rows


def person_of(ws_id: str) -> str:
    for _, row in read_tables(REGISTRY):
        if row.get("ID") == ws_id:
            return row.get("使用者", "")
    return ""


def remote_state(fetch: bool) -> list[str]:
    notes = []
    if fetch:
        try:
            git("fetch", "origin")
        except RuntimeError as err:
            notes.append(f"[!] fetch 失败，以下基于本地已有的远程引用：{err.splitlines()[0]}")
    try:
        behind, ahead = git("rev-list", "--left-right", "--count", f"{REMOTE}...HEAD").split()
    except RuntimeError:
        return notes + [f"[!] 找不到 {REMOTE}"]
    if behind == "0" and ahead == "0":
        notes.append("远程：与 origin/main 一致")
    else:
        if behind != "0":
            notes.append(f"[!] 远程：落后 {behind} 个提交，先 git pull --rebase")
        if ahead != "0":
            notes.append(f"[!] 远程：本地有 {ahead} 个提交未推送")
    return notes


def worktree_state() -> list[str]:
    changed = [line for line in git("status", "--porcelain").splitlines() if line.strip()]
    if not changed:
        return ["工作区：干净"]
    out = [f"[!] 工作区：{len(changed)} 个未提交改动"]
    out += [f"    {line}" for line in changed[:5]]
    if len(changed) > 5:
        out.append("    ……")
    out.append("    若不是你改的（例如刚跑过引擎），可能是新的假脏问题，见协作总纲第六节")
    return out


def new_commits(last_seen: str, my_id: str) -> tuple[list[str], list[str]]:
    valid = bool(last_seen) and subprocess.run(
        [GIT, "cat-file", "-e", f"{last_seen}^{{commit}}"], cwd=REPO, capture_output=True
    ).returncode == 0
    fmt = "--format=%h\x1f%an\x1f%ad\x1f%s"
    date = "--date=format:%m-%d %H:%M"
    if valid:
        log = git("log", fmt, date, f"{last_seen}..{REMOTE}")
        hub = git("diff", "--name-only", last_seen, REMOTE, "--", *HUB_PATHS) if log else ""
    else:
        log = git("log", fmt, date, "-n", "10", REMOTE)
        hub = ""
    commits = []
    for line in filter(None, log.splitlines()):
        sha, author, when, subject = line.split("\x1f", 3)
        tag = TAG.match(subject)
        who = tag.group(1) if tag else author
        mark = "（本区）" if tag and tag.group(1) == my_id else ""
        commits.append(f"  {sha} {when} {who:<8} {TAG.sub('', subject)}{mark}")
    if not valid:
        commits.insert(0, "  （首次运行，列出最近 10 个提交）")
    return commits, [f"  {p}" for p in hub.splitlines() if p]


def workspace_overview() -> list[str]:
    out = []
    today = dt.date.today()
    for path in sorted(STATUS_DIR.glob("ws*.md")):
        fields = {row.get("字段", ""): row.get("内容", "") for _, row in read_tables(path)}
        state = fields.get("状态", "?")
        doing = fields.get("正在做", "—")
        rel = path.relative_to(REPO).as_posix()
        stamp = git("log", "-1", "--format=%cs", "--", rel, check=False)
        line = f"  {path.stem:<4} {state:<4} {doing}"
        if stamp:
            line += f"  （更新于 {stamp}）"
            age = (today - dt.date.fromisoformat(stamp)).days
            if state in ACTIVE_STATES and age > STALE_DAYS:
                line += f"  [!] 已 {age} 天未更新，确认是否仍在做"
        out.append(line)
    return out or ["  （没有状态文件）"]


def waiting_for(my_id: str, person: str) -> list[str]:
    keys = {my_id, "全体"} | ({person} if person else set())
    out = []
    for section, row in read_tables(TODO):
        if "已完结" in section or "规则" in section:
            continue
        who = row.get("等谁", "")
        if any(k and k in who for k in keys):
            title = re.sub(r"^[一二三四五六七八九十]+、", "", section)
            item = next(iter(row.values()), "")
            need = row.get("需要什么") or row.get("说明") or row.get("依赖") or ""
            out.append(f"  [{title}] {item} — 等 {who}：{need}")
    return out


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="开工同步汇总")
    parser.add_argument("--init", metavar="WS_ID", help="登记本 clone 的工作区 ID，例如 ws1")
    parser.add_argument("--peek", action="store_true", help="只看不记录本次同步位置")
    parser.add_argument("--no-fetch", action="store_true", help="不执行 git fetch")
    parser.add_argument("--no-proxy", action="store_true", help="忽略系统代理，强制直连")
    args = parser.parse_args()

    global NO_PROXY
    NO_PROXY = args.no_proxy

    ws = load_ws()
    if args.init:
        if not WS_ID.match(args.init):
            sys.exit("工作区 ID 格式应为 ws<N>，例如 ws3")
        ws["id"] = args.init
        save_ws(ws)
        print(f"已登记本 clone 为 {args.init}（写入 .workspace，不入库）")
        if not person_of(args.init):
            print(f"[!] 工作区登记里还没有 {args.init}，请补一行：docs/project/03_工作区登记.md")
        return 0

    my_id = ws.get("id", "")
    if not my_id:
        print("尚未登记本 clone 是哪个工作区，请先运行：python tools/sync_status.py --init ws<N>")
        return 2
    person = person_of(my_id)

    print(f"== 同步状态（{my_id}{' · ' + person if person else ''}）==")
    proxy = git_env().get("HTTPS_PROXY", "")
    if not args.no_fetch:
        print(f"网络：{'经系统代理 ' + proxy if proxy else '直连（如拉取很慢，检查系统代理或加 --no-proxy 对照）'}")
    for line in remote_state(not args.no_fetch) + worktree_state():
        print(line)
    if not GODOT.exists():
        print("提示：本机未安装 Godot 4.7.2（只做文档 / 美术可忽略；需要跑游戏先执行 tools/setup_godot.ps1）")

    commits, hub = new_commits(ws.get("last_seen", ""), my_id)
    print(f"\n== 上次同步以来的远程提交（{len([c for c in commits if not c.startswith('  （')])}）==")
    print("\n".join(commits) if commits else "  无")
    if hub:
        print("\n== 中枢 / 共享配置有变动（建议重读）==")
        print("\n".join(hub))

    print("\n== 各工作区状态 ==")
    print("\n".join(workspace_overview()))

    pending = waiting_for(my_id, person)
    print(f"\n== 等待本区 / {person or my_id} 的事项（{len(pending)}）==")
    print("\n".join(pending) if pending else "  无")

    if not args.peek:
        try:
            ws["last_seen"] = git("rev-parse", REMOTE)
            save_ws(ws)
        except RuntimeError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
