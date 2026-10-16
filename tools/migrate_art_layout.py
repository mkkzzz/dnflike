"""Apply and verify the explicit art/catalog.json layout migration."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GIT = shutil.which("git") or r"C:\Program Files\Git\bin\git.exe"
CATALOG = ROOT / "art/catalog.json"
TEXT_SUFFIXES = {".py", ".md", ".json", ".ps1", ".gd", ".tscn", ".tres"}
LINK = re.compile(r"(!?\[[^\]]*\]\()([^)]+)(\))")
ART_PATH = re.compile(r"(?<![\w/])art/[\w./\\\-\u0080-\uffff]+")
PATH_CHAIN = re.compile(r"(['\"])art\1(?:\s*/\s*(['\"])[^'\"\n]+\2)+")
RELATIVE = re.compile(r"(?P<quote>['\"])(?P<path>\.\./[^'\"\n]+)(?P=quote)")


def load_catalog() -> dict:
    return json.loads(CATALOG.read_text(encoding="utf-8"))


def relocate(path: str, moves: list[dict]) -> str:
    path = path.replace("\\", "/")
    for move in sorted(moves, key=lambda m: len(m["from"]), reverse=True):
        old = move["from"]
        if path == old or path.startswith(old + "/"):
            return move["to"] + path[len(old):]
    return path


def repository_path(path: Path) -> str | None:
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return None


def frozen(path: str, catalog: dict) -> bool:
    return any(path == prefix or path.startswith(prefix) for prefix in catalog["migration"]["preserve_historical_documents"])


def rewrite(text: str, old_file: str, new_file: str, moves: list[dict]) -> str:
    old_parent = (ROOT / old_file).parent
    new_parent = (ROOT / new_file).parent
    review = new_parent / "independent_review.json"
    if Path(old_file).name == "calibration_used.json" and review.is_file():
        config_path = json.loads(review.read_text(encoding="utf-8")).get("original_config")
        if config_path:
            old_parent = (ROOT / config_path).parent
            new_parent = (ROOT / relocate(config_path, moves)).parent

    def relative_target(raw: str) -> str:
        if raw.startswith(("http:", "https:", "mailto:", "#", "res://")):
            return raw
        target, marker, fragment = raw.partition("#")
        old_target = repository_path(old_parent / target)
        if old_target is None:
            return raw
        new_target = relocate(old_target, moves)
        if new_target == old_target and old_parent == new_parent:
            return raw
        if not (ROOT / new_target).exists():
            return raw
        result = os.path.relpath(ROOT / new_target, new_parent).replace("\\", "/")
        return result + (marker + fragment if marker else "")

    if old_file.endswith(".md"):
        text = LINK.sub(lambda m: m[1] + relative_target(m[2]) + m[3], text)
    else:
        text = RELATIVE.sub(lambda m: m["quote"] + relative_target(m["path"]) + m["quote"], text)
    text = PATH_CHAIN.sub(lambda m: repr(relocate("/".join(re.findall(r"['\"]([^'\"]+)['\"]", m[0])), moves)), text)
    return ART_PATH.sub(lambda m: relocate(m[0], moves), text)


def tracked_files() -> list[str]:
    result = subprocess.run([GIT, "-c", "core.quotepath=false", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True)
    return [p for p in result.stdout.decode("utf-8").split("\0") if p]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def apply(catalog: dict) -> None:
    if catalog["migration"]["status"] != "planned":
        raise ValueError("Migration already applied; use --check")
    moves = catalog["migration"]["moves"]
    completed = catalog["migration"].setdefault("completed_moves", [])
    inverse = [{"from": m["to"], "to": m["from"]} for m in moves if m["from"] in completed]
    tracked = [relocate(p, inverse) for p in tracked_files()]
    before = {relocate(p.relative_to(ROOT).as_posix(), inverse): digest(p) for p in (ROOT / "art").rglob("*") if p.is_file() and p != CATALOG}
    text_files = set(tracked) | {relocate(p.relative_to(ROOT).as_posix(), inverse) for base in ("art", "docs") for p in (ROOT / base).rglob("*") if p.is_file()}
    for move in moves:
        source, target = ROOT / move["from"], ROOT / move["to"]
        if move["from"] in completed:
            if not target.exists():
                raise FileNotFoundError(move["to"])
            continue
        if not source.exists():
            raise FileNotFoundError(move["from"])
        if target.exists():
            raise FileExistsError(move["to"])
    for move in moves:
        if move["from"] in completed:
            continue
        source, target = ROOT / move["from"], ROOT / move["to"]
        files = sorted(source.rglob("*")) if source.is_dir() else [source]
        for path in files:
            if not path.is_file():
                continue
            destination = target / path.relative_to(source) if source.is_dir() else target
            if destination.exists():
                raise FileExistsError(str(destination))
            destination.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run([GIT, "mv", "--", path.relative_to(ROOT).as_posix(), destination.relative_to(ROOT).as_posix()], cwd=ROOT, check=True)
        if source.is_dir():
            directories = sorted((p for p in source.rglob("*") if p.is_dir()), key=lambda p: len(p.parts), reverse=True) + [source]
            for directory in directories:
                if not any(directory.iterdir()):
                    try:
                        directory.rmdir()
                    except PermissionError:
                        catalog["migration"].setdefault("empty_dirs_locked", []).append(directory.relative_to(ROOT).as_posix())
        completed.append(move["from"])
        CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    unchanged_binary = []
    for old, expected in before.items():
        new = relocate(old, moves)
        path = ROOT / new
        if not path.is_file() or digest(path) != expected:
            raise ValueError(f"File changed during move: {old}")
        if path.suffix.lower() not in TEXT_SUFFIXES:
            unchanged_binary.append({"from": old, "to": new, "sha256": expected})
    edited = []
    for old in sorted(text_files):
        new = relocate(old, moves)
        path = ROOT / new
        if path == CATALOG or path.name == Path(__file__).name or path.suffix.lower() not in TEXT_SUFFIXES or frozen(old, catalog):
            continue
        if old.startswith((".codebuddy/", ".codewiki/", "tools/godot/", "temp/")) or not path.is_file():
            continue
        original = path.read_bytes()
        text = original.decode("utf-8")
        updated = rewrite(text, old, new, moves)
        if updated != text:
            path.write_bytes(updated.encode("utf-8"))
            edited.append(new)
    for old in ("art/characters", "art/monsters/goblin", "art/monsters", "art/environments"):
        path = ROOT / old
        if path.is_dir() and not any(path.iterdir()):
            path.rmdir()
    report = ROOT / "docs/reports/ws1/2026-10/2026-10-16_art_layout_validation.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"verified_art_files": len(before), "updated_text_files": edited, "binary_integrity": unchanged_binary}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    catalog["migration"].update({"status": "applied", "verified_art_files": len(before), "binary_file_count": len(unchanged_binary), "audit_file": report.relative_to(ROOT).as_posix()})
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"ART_MIGRATION_APPLIED moved_verified={len(before)} text_updated={len(edited)} binary_unchanged={len(unchanged_binary)}")


def check(catalog: dict) -> None:
    if catalog["migration"]["status"] != "applied":
        raise ValueError("Migration not applied")
    audit = json.loads((ROOT / catalog["migration"]["audit_file"]).read_text(encoding="utf-8"))
    for item in audit["binary_integrity"]:
        path = ROOT / item["to"]
        if not path.is_file() or digest(path) != item["sha256"]:
            raise ValueError(f"Missing or altered binary: {item['to']}")
    for value in catalog["assets"].values():
        if not (ROOT / value).is_file():
            raise FileNotFoundError(value)
    leftovers = [move["from"] for move in catalog["migration"]["moves"] if (ROOT / move["from"]).is_file() or ((ROOT / move["from"]).is_dir() and any(p.is_file() for p in (ROOT / move["from"]).rglob("*")))]
    if leftovers:
        raise ValueError(f"Unmigrated roots: {leftovers}")
    v7 = ROOT / "art/animations/players/swordsman/v7"
    config_path = v7 / "sources/pilot_c2.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    saved = json.loads((v7 / "exports/pilot_c2/calibration_used.json").read_text(encoding="utf-8"))
    manifest = json.loads((v7 / "exports/pilot_c2/manifest.json").read_text(encoding="utf-8"))
    if config != saved or manifest["config_sha256"] != digest(config_path):
        raise ValueError("V7 saved config or config hash does not match relocated source")
    print(f"ART_LAYOUT_CHECK_OK binary_unchanged={len(audit['binary_integrity'])} assets={len(catalog['assets'])} v7_config_hash=matched")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()
    catalog = load_catalog()
    if args.apply:
        apply(catalog)
    else:
        check(catalog)


if __name__ == "__main__":
    main()
