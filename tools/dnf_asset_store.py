"""Versioned DNF asset archives outside the source checkout (Python stdlib only)."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "game_dnf/asset_store.json"
API = "https://api.github.com"


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def cache_home() -> Path:
    configured = os.environ.get("DNFLIKE_ASSET_HOME")
    if not configured:
        workspace = ROOT / ".workspace"
        if workspace.exists():
            configured = next((line.split("=", 1)[1].strip() for line in workspace.read_text(
                encoding="utf-8").splitlines() if line.startswith("dnf_asset_home=")), None)
    default = Path(ROOT.anchor) / "dnflike-assets" if os.name == "nt" else Path.home() / ".cache/dnflike/assets"
    home = Path(configured).expanduser().resolve() if configured else default.resolve()
    if home == ROOT or ROOT in home.parents:
        raise ValueError("Asset cache must be outside this source checkout.")
    return home


def token() -> str:
    value = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if value:
        return value
    result = subprocess.run(["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n", text=True, capture_output=True,
        env=dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never"))
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    if not fields.get("password"):
        raise RuntimeError("GitHub credentials unavailable. Sign in to Git or set GH_TOKEN locally.")
    return fields["password"]


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected and urllib.parse.urlparse(newurl).netloc != "api.github.com":
            redirected.remove_header("Authorization")
        return redirected


class GitHub:
    def __init__(self, direct=False):
        self._token = token()
        handlers = [urllib.request.ProxyHandler({})] if direct else []
        self.opener = urllib.request.build_opener(*handlers, SafeRedirect())

    def open(self, url, *, method="GET", data=None, accept="application/vnd.github+json", headers=None):
        if not url.startswith((API + "/", "https://uploads.github.com/")):
            raise ValueError("Only GitHub API/upload endpoints may receive credentials.")
        values = {"Authorization": "Bearer " + self._token, "Accept": accept,
                  "User-Agent": "dnflike-asset-store", "X-GitHub-Api-Version": "2022-11-28"}
        values.update(headers or {})
        request = urllib.request.Request(url, data=data, method=method, headers=values)
        return self.opener.open(request, timeout=180)

    def json(self, route, *, method="GET", value=None):
        data = json.dumps(value).encode() if value is not None else None
        with self.open(API + route, method=method, data=data,
                       headers={"Content-Type": "application/json"} if data else {}) as response:
            payload = response.read()
        return json.loads(payload) if payload else None


def pack(library: Path, runtime: Path, output: Path, version: str, repository: str) -> dict:
    """Keep every extracted file. Never copy the original client executables/server."""
    if any(output == base or base in output.parents for base in [library, runtime]):
        raise ValueError("Archive output must not be inside its own sources.")
    if output.exists() and any(output.iterdir()):
        raise ValueError("Use a new, empty archive output directory; published versions are immutable.")
    output.mkdir(parents=True, exist_ok=True)
    packs = []
    for kind, base in [("runtime", runtime), ("library_v1", library)]:
        files = sorted(p for p in base.rglob("*") if p.is_file() and not p.name.endswith(".import")
                       and p.name != ".asset_store_install.json" and not p.name.startswith(".dnf-"))
        if not files:
            raise ValueError("Empty source directory: " + str(base))
        groups, group, size = [], [], 0
        for path in files:
            if path.is_symlink():
                raise ValueError("Symlink source unsupported: " + str(path))
            n = path.stat().st_size
            if group and size + n > 512 * 1024 * 1024:
                groups.append(group)
                group, size = [], 0
            group.append(path)
            size += n
        if group:
            groups.append(group)
        for index, group in enumerate(groups, 1):
            name = f"{kind}-{index:02d}.zip"
            target = output / name
            entries = []
            with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
                for path in group:
                    name_in_zip = kind + "/" + path.relative_to(base).as_posix()
                    entries.append({"path": name_in_zip, "bytes": path.stat().st_size,
                                    "sha256": digest(path)})
                    archive.write(path, name_in_zip)
                archive.writestr("_manifests/" + name + ".json",
                                 json.dumps(entries, ensure_ascii=False).encode("utf-8"))
            pack_info = {"name": name, "kind": kind, "bytes": target.stat().st_size,
                         "sha256": digest(target), "files": len(entries),
                         "unpacked_bytes": sum(x["bytes"] for x in entries)}
            if pack_info["bytes"] >= 2 * 1024**3:
                raise ValueError("Archive exceeds the GitHub Release per-file limit: " + name)
            packs.append(pack_info)
            print("PACK " + json.dumps(pack_info), flush=True)
    result = {"schema": "dnflike_asset_store/1", "version": version, "repository": repository,
              "tag": version, "packs": packs}
    write_json(output / "asset_store.json", result)
    return result


def validate_archive(path: Path, entry: dict) -> list:
    if path.stat().st_size != entry["bytes"] or digest(path) != entry["sha256"]:
        raise ValueError("Archive SHA256 mismatch: " + path.name)
    with zipfile.ZipFile(path) as archive:
        manifest_name = "_manifests/" + entry["name"] + ".json"
        inventory = json.loads(archive.read(manifest_name))
        if len(inventory) != entry["files"] or sum(x["bytes"] for x in inventory) != entry["unpacked_bytes"]:
            raise ValueError("Inventory size mismatch: " + path.name)
        expected = {x["path"]: x for x in inventory}
        if (len(expected) != len(inventory) or len(archive.namelist()) != len(expected) + 1
                or set(archive.namelist()) != set(expected) | {manifest_name}):
            raise ValueError("Archive contains duplicate/unregistered paths.")
        for info in archive.infolist():
            parts = PurePosixPath(info.filename)
            if (parts.is_absolute() or ".." in parts.parts or "\\" in info.filename
                    or ":" in info.filename or stat.S_ISLNK(info.external_attr >> 16)):
                raise ValueError("Unsafe archive member: " + info.filename)
            if info.filename in expected:
                if parts.parts[0] != entry["kind"] or info.file_size != expected[info.filename]["bytes"]:
                    raise ValueError("Invalid archive member size/root.")
    return inventory


def install_archive(path: Path, entry: dict, destination: Path) -> list:
    inventory = validate_archive(path, entry)
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path) as archive:
        for info in inventory:
            target = destination / info["path"]
            if destination.resolve() not in target.resolve().parents:
                raise ValueError("Extraction path escapes the asset version.")
            if target.exists():
                if target.is_symlink() or not target.is_file() or digest(target) != info["sha256"]:
                    raise ValueError("Existing asset differs; preserved without overwrite: " + str(target))
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=target.parent, prefix=".dnf-", delete=False) as output:
                temporary = Path(output.name)
                with archive.open(info["path"]) as source:
                    shutil.copyfileobj(source, output, 1024 * 1024)
            if digest(temporary) != info["sha256"]:
                raise ValueError("Extracted asset SHA256 mismatch: " + info["path"])
            temporary.replace(target)
    write_json(destination / "_installed" / (entry["name"] + ".json"),
               {"sha256": entry["sha256"], "files": entry["files"]})
    print("INSTALLED", entry["name"], entry["files"], "verified files", flush=True)
    return inventory


def download(github: GitHub, asset: dict, entry: dict, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and digest(destination) == entry["sha256"]:
        return
    temporary = destination.with_suffix(".downloading")
    for attempt in range(3):
        try:
            with github.open(asset["url"], accept="application/octet-stream") as source, temporary.open("wb") as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
            if temporary.stat().st_size != entry["bytes"] or digest(temporary) != entry["sha256"]:
                raise ValueError("Downloaded archive SHA256 mismatch.")
            temporary.replace(destination)
            return
        except (OSError, ValueError):
            if attempt == 2:
                raise
            time.sleep(2 * (attempt + 1))


def sync(lock: dict, home: Path, full: bool, local_archives: Path | None, project: Path | None) -> None:
    version = lock["version"]
    if not version or PurePosixPath(version).name != version or version in [".", ".."] or ":" in version or "\\" in version:
        raise ValueError("Invalid immutable version name.")
    version_home = home / version
    archives_home = home / "downloads" / version
    entries = [p for p in lock["packs"] if full or p["kind"] == "runtime"]
    runtime_inventory = []
    for entry in entries:
        name = entry["name"]
        if (not name or PurePosixPath(name).name != name or ":" in name or "\\" in name
                or entry["kind"] not in ["runtime", "library_v1"]):
            raise ValueError("Invalid package name or kind.")
    github, assets = None, {}
    if not local_archives:
        github = GitHub()
        try:
            release = github.json("/repos/" + lock["repository"] + "/releases/tags/" + urllib.parse.quote(lock["tag"]))
        except urllib.error.HTTPError as error:
            if error.code in [403, 404]:
                raise RuntimeError("Cannot read the shared asset release. Accept the repository invitation and "
                                   "ensure the signed-in account/token can read " + lock["repository"] + ".") from None
            raise
        if release["draft"]:
            raise ValueError("Asset release is still a draft.")
        assets = {a["name"]: a for a in release["assets"]}
    for entry in entries:
        archive = (local_archives or archives_home) / entry["name"]
        if not local_archives:
            if entry["name"] not in assets:
                raise ValueError("Missing release asset: " + entry["name"])
            print("FETCH", entry["name"], flush=True)
            download(github, assets[entry["name"]], entry, archive)
        inventory = install_archive(archive, entry, version_home)
        if entry["kind"] == "runtime":
            runtime_inventory.extend(inventory)
    runtime = version_home / "runtime"
    if project:
        target_root = project / "assets_local"
        if target_root.is_symlink():
            raise ValueError("Project consumption directory must not be a symbolic link.")
        stamp_path = target_root / ".asset_store_install.json"
        previous = json.loads(stamp_path.read_text(encoding="utf-8")) if stamp_path.exists() else {}
        old_hashes = previous.get("files", {})
        planned = []
        new_hashes = {}
        for info in runtime_inventory:
            relative = PurePosixPath(info["path"]).relative_to("runtime").as_posix()
            source = runtime / relative
            target = target_root / relative
            if project.resolve() not in target.resolve().parents:
                raise ValueError("Project asset path escapes the checkout.")
            current_hash = digest(target) if target.exists() else None
            if current_hash and current_hash != info["sha256"] and current_hash != old_hashes.get(relative):
                raise ValueError("Project asset differs; preserved without overwrite: " + str(target))
            new_hashes[relative] = info["sha256"]
            if current_hash != info["sha256"]:
                planned.append((source, target))
        # Preflight every managed file before replacing any versioned consumer.
        # Files added to the external runtime cache are never copied implicitly.
        for source, target in planned:
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=target.parent, prefix=".dnf-", delete=False) as output:
                temporary = Path(output.name)
                with source.open("rb") as input_file:
                    shutil.copyfileobj(input_file, output, 1024 * 1024)
            temporary.replace(target)
        write_json(stamp_path, {"schema":"dnflike_consumption/1", "version":version,
            "runtime_packs":{p["name"]:p["sha256"] for p in entries if p["kind"]=="runtime"},
            "files":new_hashes})
        print("PROJECT", target_root, flush=True)
    print("CACHE", version_home, flush=True)
    if full:
        print("LIBRARY", version_home / "library_v1", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("pack")
    create.add_argument("--library", type=Path, required=True)
    create.add_argument("--runtime", type=Path, default=ROOT / "game_dnf/assets_local")
    create.add_argument("--output", type=Path, required=True)
    create.add_argument("--version", required=True)
    create.add_argument("--repository", required=True)
    fetch = commands.add_parser("sync")
    fetch.add_argument("--lock", type=Path, default=LOCK)
    fetch.add_argument("--home", type=Path)
    fetch.add_argument("--full", action="store_true")
    fetch.add_argument("--local-archives", type=Path)
    fetch.add_argument("--project", type=Path, default=ROOT / "game_dnf")
    args = parser.parse_args()
    if args.command == "pack":
        pack(args.library.resolve(), args.runtime.resolve(), args.output.resolve(), args.version, args.repository)
    else:
        home = args.home.resolve() if args.home else cache_home()
        if home == ROOT or ROOT in home.parents:
            raise ValueError("Full asset cache must be outside the source checkout.")
        sync(json.loads(args.lock.read_text(encoding="utf-8")), home, args.full,
             args.local_archives.resolve() if args.local_archives else None, args.project.resolve())


if __name__ == "__main__":
    main()
