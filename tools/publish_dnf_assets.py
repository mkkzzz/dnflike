"""Publish prepared archives as a GitHub Release; never put the binaries in Git."""
from __future__ import annotations

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import time
import urllib.error
import urllib.parse

from dnf_asset_store import GitHub, digest, write_json


class ProgressFile:
    def __init__(self, path: Path):
        self.path = path
        self.file = path.open("rb")
        self.size = path.stat().st_size
        self.sent = 0
        self.last = time.monotonic()

    def read(self, count=-1):
        # Large TLS writes avoid tiny per-write proxy/TCP throughput on some hosts.
        value = self.file.read(max(count, 1024 * 1024) if count >= 0 else count)
        self.sent += len(value)
        if time.monotonic() - self.last > 15:
            print(f"UPLOAD {self.path.name}: {self.sent}/{self.size} bytes sent", flush=True)
            self.last = time.monotonic()
        return value

    def close(self):
        self.file.close()


def ensure_repository(github: GitHub, repository: str, private: bool) -> dict:
    try:
        current = github.json("/repos/" + repository)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        owner, name = repository.split("/")
        account = github.json("/user")
        if account["login"].lower() != owner.lower():
            raise ValueError("New asset repositories must belong to the authenticated account.")
        current = github.json("/user/repos", method="POST", value={
            "name": name, "private": private, "description": "Versioned external DNF asset store for dnflike workspaces",
            "auto_init": False})
    if bool(current["private"]) != private:
        raise ValueError("Existing repository audience differs; no access settings were changed.")
    if current["size"] == 0:
        text = ("# dnflike shared assets\n\n"
                "Large immutable resource archives live in Releases, outside the game checkout.\n"
                "Use tools/dnf_asset_store.py from mkkzzz/dnflike to verify and install.\n"
                "Local client resources are preserved as supplied; ownership is not transferred.\n")
        try:
            github.json("/repos/" + repository + "/contents/README.md", method="PUT", value={
                "message": "[ws2] 资源：初始化独立共享资源库", "content": base64.b64encode(text.encode()).decode(),
                "branch": "main"})
        except urllib.error.HTTPError as error:
            if error.code != 422:
                raise
            # A populated existing README is not overwritten on a resumed publish.
            github.json("/repos/" + repository + "/contents/README.md")
        current = github.json("/repos/" + repository)
    return current


def share_with_collaborators(github: GitHub, source: str, target: str) -> list:
    result = []
    owner = target.split("/")[0].lower()
    organization_owned = github.json("/repos/" + target)["owner"]["type"] == "Organization"
    pending = {x["invitee"]["login"].lower(): x for x in github.json("/repos/" + target + "/invitations?per_page=100")}
    current = {x["login"].lower(): x for x in github.json("/repos/" + target + "/collaborators?per_page=100")}
    page = 1
    while True:
        collaborators = github.json(f"/repos/{source}/collaborators?per_page=100&page={page}")
        for person in collaborators:
            login = person["login"]
            if login.lower() == owner:
                continue
            if login.lower() in pending or login.lower() in current:
                result.append({"login": login, "permission": "read" if organization_owned else "write",
                               "status": "invitation_pending" if login.lower() in pending else "access_granted"})
                continue
            # Personal repositories only have owner/collaborator access. GitHub
            # rejects read-only invitations there; preserve an existing writer's
            # project role, and never upgrade a read-only source collaborator.
            if not organization_owned and not person["permissions"].get("push"):
                raise ValueError("Personal asset repo cannot mirror a read-only collaborator: " + login)
            response = github.json(f"/repos/{target}/collaborators/{urllib.parse.quote(login)}",
                                   method="PUT", value={"permission": "pull"} if organization_owned else {})
            result.append({"login": login, "permission": "read" if organization_owned else "write",
                           "status": "invitation_pending" if response else "access_granted"})
        if len(collaborators) < 100:
            break
        page += 1
    return result


def publish(folder: Path, private: bool, share_from: str | None, workers: int, direct=False,
            retry_incomplete=False, only: list[str] | None = None) -> None:
    lock_path = folder / "asset_store.json"
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    repo = lock["repository"]
    github = GitHub(direct=direct)
    repository = ensure_repository(github, repo, private)
    access = share_with_collaborators(github, share_from, repo) if private and share_from else []
    print("REPOSITORY", repo, "private=" + str(private), "collaborators=" + json.dumps(access), flush=True)
    tag = urllib.parse.quote(lock["tag"], safe="")
    try:
        release = github.json(f"/repos/{repo}/releases/tags/{tag}")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        # GitHub tags lookup may not return an existing draft; reconcile by exact tag.
        drafts = github.json(f"/repos/{repo}/releases?per_page=100")
        matches = [r for r in drafts if r["tag_name"] == lock["tag"]]
        release = matches[0] if matches else github.json(f"/repos/{repo}/releases", method="POST", value={
            "tag_name": lock["tag"], "target_commitish": repository["default_branch"],
            "name": "DNF native shared assets v1", "draft": True, "prerelease": False,
            "body": "Complete extracted library plus selected runtime sources/atlases/audio.\n"
                    "Checksums and file inventories accompany every archive.\n"
                    "No original client executables or server directories are included.\n"
                    "Install using the asset_store.json lock in mkkzzz/dnflike."})
    release_id = release["id"]
    prefix = f"/repos/{repo}/releases/{release_id}"
    existing = {asset["name"]: asset for asset in github.json(prefix + "/assets?per_page=100")}
    entries = list(lock["packs"]) + [{"name": "asset_store.json", "bytes": lock_path.stat().st_size,
                                      "sha256": digest(lock_path)}]
    selected = entries
    if only:
        if set(only) - {entry["name"] for entry in entries}:
            raise ValueError("Unknown selected archive.")
        selected = [entry for entry in entries if entry["name"] in only]

    def upload(entry):
        path = folder / entry["name"]
        if path.stat().st_size != entry["bytes"] or digest(path) != entry["sha256"]:
            raise ValueError("Local archive changed: " + entry["name"])
        old = existing.get(entry["name"])
        if old:
            if (old["state"] == "starter" and old.get("digest") is None
                    and old["size"] in [0, entry["bytes"]] and release["draft"] and retry_incomplete):
                # Explicit operator flag: previous uploader must have stopped.
                # Starter size is the declared Content-Length, even if interrupted.
                # Only remove an unfinished, unhashed member of this exact draft.
                github.json(f"/repos/{repo}/releases/assets/{old['id']}", method="DELETE")
                old = None
        if old:
            if old["size"] != entry["bytes"] or old.get("digest") != "sha256:" + entry["sha256"]:
                raise ValueError("Existing release asset differs; preserved: " + entry["name"])
            print("REMOTE VERIFIED", entry["name"], flush=True)
            return old
        url = release["upload_url"].split("{", 1)[0] + "?name=" + urllib.parse.quote(entry["name"])
        source = ProgressFile(path)
        try:
            with github.open(url, method="POST", data=source,
                             headers={"Content-Type": "application/octet-stream",
                                      "Content-Length": str(entry["bytes"])}) as response:
                asset = json.load(response)
        finally:
            source.close()
        if asset["state"] != "uploaded" or asset["size"] != entry["bytes"] or asset.get("digest") != "sha256:" + entry["sha256"]:
            raise ValueError("Remote digest not confirmed: " + entry["name"])
        print("REMOTE VERIFIED", entry["name"], entry["bytes"], flush=True)
        return asset

    def reported_upload(entry):
        try:
            return upload(entry)
        except urllib.error.HTTPError as error:
            print("UPLOAD FAILED", entry["name"], error.code, error.read().decode("utf-8", "replace"), flush=True)
            raise
        except Exception as error:
            print("UPLOAD FAILED", entry["name"], type(error).__name__, str(error), flush=True)
            raise

    with ThreadPoolExecutor(max_workers=workers) as pool:
        uploaded = list(pool.map(reported_upload, selected))
    if only:
        print("SELECTED UPLOADS COMPLETE; release left in its existing draft/published state", flush=True)
        return
    if release["draft"]:
        release = github.json(prefix, method="PATCH", value={"draft": False})
    remote = github.json(prefix)
    by_name = {a["name"]: a for a in remote["assets"]}
    for entry in entries:
        value = by_name[entry["name"]]
        if value["size"] != entry["bytes"] or value.get("digest") != "sha256:" + entry["sha256"]:
            raise ValueError("Final remote verification failed.")
    receipt = {"repository": repo, "private": private, "release_id": release_id,
               "url": remote["html_url"], "draft": remote["draft"], "collaborators": access,
               "assets": [{k: a.get(k) for k in ["id", "name", "size", "digest", "browser_download_url"]} for a in uploaded]}
    write_json(folder / "publish_receipt.json", receipt)
    print("PUBLISHED", receipt["url"], "draft=" + str(receipt["draft"]), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--access", choices=["private", "public"], required=True)
    parser.add_argument("--share-from", help="Source project collaborators; read-only in org repos, existing writer role in personal repos")
    parser.add_argument("--workers", type=int, choices=range(1, 9), default=2)
    parser.add_argument("--direct", action="store_true", help="Bypass configured proxies for this publish only")
    parser.add_argument("--retry-incomplete", action="store_true", help="After stopping an interrupted uploader, remove its unhashed starter assets from this draft")
    parser.add_argument("--only", action="append", help="Upload only this named member; do not publish the release")
    args = parser.parse_args()
    publish(args.folder.resolve(), args.access == "private", args.share_from, args.workers,
            args.direct, args.retry_incomplete, args.only)
