"""Disk safety and cross-checkout integration checks for the shared asset store."""
from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import urllib.request
import zipfile

import dnf_asset_store as store


class SharedAssets(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dnflike-asset-check-")
        self.root = Path(self.temporary.name)
        self.library = self.root / "input-library"
        self.runtime = self.root / "input-runtime"
        self.library.mkdir()
        self.runtime.mkdir()
        (self.library / "角色.img").write_bytes(b"original-pixels\x00\xff")
        (self.library / "catalog.sqlite").write_bytes(b"catalog-fixture")
        (self.runtime / "manifest.json").write_text('{"schema":"fixture"}')
        (self.runtime / "scene.png").write_bytes(b"png-fixture")
        (self.runtime / "scene.png.import").write_text("cache metadata")
        self.archives = self.root / "archives"
        with contextlib.redirect_stdout(io.StringIO()):
            self.lock = store.pack(self.library, self.runtime, self.archives, "v1", "fixture/assets")

    def tearDown(self):
        self.temporary.cleanup()

    def sync(self, full=False, project="workspace-a"):
        with contextlib.redirect_stdout(io.StringIO()):
            store.sync(self.lock, self.root / "external-cache", full, self.archives, self.root / project)

    def test_two_checkouts_share_one_external_library_and_only_copy_runtime(self):
        self.sync(full=True)
        self.sync(full=True, project="workspace-b")
        external = self.root / "external-cache/v1/library_v1/角色.img"
        self.assertEqual(store.digest(external), store.digest(self.library / "角色.img"))
        for name in ["workspace-a", "workspace-b"]:
            target = self.root / name / "assets_local"
            self.assertEqual(store.digest(target / "scene.png"), store.digest(self.runtime / "scene.png"))
            self.assertFalse((target / "catalog.sqlite").exists())
            self.assertFalse((target / "scene.png.import").exists())

    def test_default_sync_does_not_extract_large_library(self):
        self.sync()
        self.assertFalse((self.root / "external-cache/v1/library_v1").exists())
        self.assertTrue((self.root / "workspace-a/assets_local/manifest.json").exists())

    def updated_version(self):
        (self.runtime / "scene.png").write_bytes(b"new-official-pixels")
        (self.runtime / "manifest.json").write_text('{"schema":"fixture-v2"}')
        with contextlib.redirect_stdout(io.StringIO()):
            self.lock = store.pack(self.library, self.runtime, self.root / "archives-v2", "v2", "fixture/assets")
        self.archives = self.root / "archives-v2"

    def test_managed_version_upgrade_updates_only_unmodified_official_files(self):
        self.sync()
        user_file = self.root / "workspace-a/assets_local/notes.txt"
        user_file.write_text("keep user notes")
        self.updated_version()
        self.sync()
        target = self.root / "workspace-a/assets_local"
        self.assertEqual((target / "scene.png").read_bytes(), b"new-official-pixels")
        self.assertEqual(json.loads((target / ".asset_store_install.json").read_text())["version"], "v2")
        self.assertEqual(user_file.read_text(), "keep user notes")

    def test_upgrade_conflict_preserves_all_project_files_before_writing(self):
        self.sync()
        target = self.root / "workspace-a/assets_local"
        old_manifest = (target / "manifest.json").read_bytes()
        (target / "scene.png").write_bytes(b"user-painted")
        self.updated_version()
        with self.assertRaisesRegex(ValueError, "preserved without overwrite"):
            self.sync()
        self.assertEqual((target / "manifest.json").read_bytes(), old_manifest)
        self.assertEqual((target / "scene.png").read_bytes(), b"user-painted")

    def test_unregistered_cache_files_do_not_enter_project(self):
        self.sync()
        extra = self.root / "external-cache/v1/runtime/unregistered.gd"
        extra.write_text("arbitrary local cache file")
        self.sync(project="workspace-b")
        self.assertFalse((self.root / "workspace-b/assets_local/unregistered.gd").exists())

    def test_conflicting_project_file_is_not_overwritten(self):
        self.sync()
        target = self.root / "workspace-a/assets_local/scene.png"
        target.write_bytes(b"other-developer-change")
        with self.assertRaisesRegex(ValueError, "preserved without overwrite"):
            self.sync()
        self.assertEqual(target.read_bytes(), b"other-developer-change")

    def test_corrupt_archive_is_rejected_before_extraction(self):
        entry = self.lock["packs"][0]
        path = self.archives / entry["name"]
        path.write_bytes(path.read_bytes()[:-20] + b"corruption")
        with self.assertRaisesRegex(ValueError, "SHA256"):
            self.sync()
        self.assertFalse((self.root / "workspace-a").exists())

    def test_registered_traversal_member_is_rejected(self):
        path = self.root / "malicious.zip"
        entries = [{"path":"runtime/../../escaped.txt", "bytes":4, "sha256":"0"*64}]
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(entries[0]["path"], b"test")
            archive.writestr("_manifests/malicious.zip.json", json.dumps(entries))
        entry = {"name":path.name,"kind":"runtime","bytes":path.stat().st_size,
                 "sha256":store.digest(path),"files":1,"unpacked_bytes":4}
        with self.assertRaisesRegex(ValueError, "Unsafe archive member"):
            store.install_archive(path, entry, self.root / "destination")
        self.assertFalse((self.root / "escaped.txt").exists())

    def test_payload_hash_is_verified_before_installing(self):
        path = self.root / "bad-payload.zip"
        entries = [{"path":"runtime/image.img", "bytes":4, "sha256":"0"*64}]
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(entries[0]["path"], b"test")
            archive.writestr("_manifests/bad-payload.zip.json", json.dumps(entries))
        entry = {"name":path.name,"kind":"runtime","bytes":path.stat().st_size,
                 "sha256":store.digest(path),"files":1,"unpacked_bytes":4}
        with self.assertRaisesRegex(ValueError, "Extracted asset SHA256"):
            store.install_archive(path, entry, self.root / "destination")
        self.assertFalse((self.root / "destination/runtime/image.img").exists())

    def test_redirect_does_not_send_github_token_to_asset_cdn(self):
        request = urllib.request.Request("https://api.github.com/repos/fixture/assets/releases/assets/1",
                                         headers={"Authorization":"Bearer test-token"})
        redirected = store.SafeRedirect().redirect_request(request, None, 302, "", {},
                                                        "https://release-assets.githubusercontent.com/file.zip")
        self.assertIsNone(redirected.get_header("Authorization"))


if __name__ == "__main__":
    unittest.main()
