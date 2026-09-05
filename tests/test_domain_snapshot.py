#!/usr/bin/env python3
"""Actual signed two-project transactions; no production key, API or upload."""

import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "scripts"), str(ROOT / "tests")]
import domain_snapshot as snapshot
import publication_plan
import render_archive as renderer
from make_deb import build


class Transactions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="apt-txn-", dir="/tmp")
        cls.root = Path(cls.temporary.name)
        cls.home = cls.root / "gpg"
        cls.home.mkdir(mode=0o700)
        cls.epoch = int(time.time()) - 10
        cls.gpg = ["gpg", "--no-options", "--homedir", str(cls.home), "--batch", "--yes",
                   "--pinentry-mode", "loopback", "--passphrase", ""]
        cls.run_gpg(["--faked-system-time", str(cls.epoch - 400 * 86400), "--quick-generate-key",
                     "Isolated test <test@example.invalid>", "ed25519", "cert", "never"])
        listing = cls.run_gpg(["--with-colons", "--list-keys"]).decode()
        cls.primary = next(line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:"))
        for _ in range(2):
            cls.run_gpg(["--faked-system-time", str(cls.epoch - 400 * 86400),
                         "--quick-add-key", cls.primary, "ed25519", "sign", "never"])
        listing = cls.run_gpg(["--with-colons", "--list-keys"]).decode()
        cls.subkeys = [line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:")][1:]

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["gpgconf", "--homedir", str(cls.home), "--kill", "gpg-agent"], capture_output=True)
        cls.temporary.cleanup()

    @classmethod
    def run_gpg(cls, args):
        result = subprocess.run(cls.gpg + args, capture_output=True, timeout=30)
        if result.returncode:
            raise AssertionError(result.stderr.decode())
        return result.stdout

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.manifest = self.work / "manifest.toml"
        self.manifest.write_text(f'''[domain]
layout = "shared-root-v1"
host = "deb.example.invalid"
base_url = "https://deb.example.invalid"
origin = "example"
keyring_package = "example-archive-keyring"
keyring_file = "/usr/share/keyrings/example-archive-keyring.pgp"
[signing]
primary_fingerprint = "{self.primary}"
signing_subkey = "{self.subkeys[0]}"
[publication]
r2_bucket = "test-bucket"
r2_account_id = "{'0' * 32}"
[release]
suite = "rolling"
codename = "rolling"
components = ["main"]
architectures = ["amd64", "arm64"]
acquire_by_hash = true
valid_until_days = 180
[[projects]]
name = "alpha"
source_repo = "test/alpha"
packages = ["alpha"]
keep_versions = 5
[[projects]]
name = "beta"
source_repo = "test/beta"
packages = ["beta"]
keep_versions = 5
''')
        self.pool = self.work / "pool"
        self.pool.mkdir()
        self.deb(self.pool, "alpha", "1.0", "amd64")
        self.deb(self.pool, "alpha", "1.0", "arm64")
        self.deb(self.pool, "beta", "1.0", "all")
        self.archive = self.make_archive(self.pool, "archive", self.epoch)

    def deb(self, pool, package, version, arch):
        path = pool / f"{package}_{version}_{arch}.deb"
        build(path, {"Package": package, "Version": version, "Architecture": arch,
                     "Maintainer": "Test <test@example.invalid>", "Description": "fixture"})
        return path

    def sign(self, archive, epoch, subkey=None):
        subkey = subkey or self.subkeys[0]
        release = archive / "dists/rolling/Release"
        for filename, mode in (("InRelease", "--clearsign"), ("Release.gpg", "--detach-sign")):
            self.run_gpg(["--faked-system-time", f"{epoch}!", "--local-user", subkey + "!",
                          "--armor", mode, "--output", str(release.parent / filename), str(release)])
        for suffix, extra in (("pgp", []), ("asc", ["--armor"])):
            (archive / f"example-archive-keyring.{suffix}").write_bytes(
                self.run_gpg(extra + ["--export", self.subkeys[0] + "!"]))

    def make_archive(self, pool, name, epoch):
        domain = renderer.load_domain(self.manifest)
        out = self.work / name
        out.mkdir()
        renderer.digests.cache_clear()
        renderer.render(domain, renderer.collect(pool, domain, "main"), out, "main", epoch)
        self.sign(out, epoch)
        return out

    def store(self):
        return snapshot.DirectoryStore(self.archive)

    def scratch(self):
        return Path(tempfile.mkdtemp(dir=self.work))

    def restore(self):
        return snapshot.restore(self.manifest, self.store(), self.scratch())

    def prepare(self, project=None, incoming=None):
        output, baseline = self.work / "merged", self.work / "baseline.json"
        snapshot.prepare(self.manifest, self.store(), self.scratch(), project, incoming, output, baseline)
        return output, baseline

    def replace_state(self, transform):
        state_path = self.archive / "dists/rolling/archive-state.json"
        state = json.loads(state_path.read_text())
        transform(state)
        state_path.write_text(json.dumps(state))
        release = self.archive / "dists/rolling/Release"
        lines = release.read_text().splitlines()
        section = None
        for i, line in enumerate(lines):
            if line in ("SHA256:", "SHA512:"):
                section = line[:-1]
            elif section and line.endswith(" archive-state.json"):
                checksum = hashlib.new(section.lower(), state_path.read_bytes()).hexdigest()
                lines[i] = f" {checksum} {state_path.stat().st_size} archive-state.json"
                (state_path.parent / "by-hash" / section / checksum).write_bytes(state_path.read_bytes())
        release.write_text("\n".join(lines) + "\n")
        self.sign(self.archive, self.epoch)

    def test_signed_roundtrip_and_candidate(self):
        binaries, baseline = self.restore()
        self.assertEqual(len(binaries), 3)
        self.assertEqual(baseline["publication_epoch"], self.epoch)
        snapshot.verify_candidate(self.manifest, self.archive, self.scratch(), self.epoch)

    def test_update_retains_other_project_exactly(self):
        incoming = self.work / "incoming"
        incoming.mkdir()
        for arch in ("amd64", "arm64"):
            self.deb(incoming, "alpha", "2.0", arch)
        merged, _ = self.prepare("alpha", incoming)
        self.assertEqual((merged / "beta_1.0_all.deb").read_bytes(), (self.pool / "beta_1.0_all.deb").read_bytes())
        self.assertEqual(len(list(merged.iterdir())), 3)

    def test_refresh_no_github_and_byte_identical_content(self):
        merged, _ = self.prepare()
        out = self.make_archive(merged, "refresh", self.epoch + 1)
        for path in self.archive.rglob("*"):
            if path.is_file() and path.name not in ("Release", "Release.gpg", "InRelease"):
                self.assertEqual(path.read_bytes(), (out / path.relative_to(self.archive)).read_bytes())
        self.assertNotEqual((out / "dists/rolling/InRelease").read_bytes(),
                            (self.archive / "dists/rolling/InRelease").read_bytes())

    def test_expired_metadata_can_be_restored_but_not_published(self):
        self.archive = self.make_archive(self.pool, "expired", self.epoch - 200 * 86400)
        self.assertEqual(len(self.restore()[0]), 3)
        with self.assertRaisesRegex(ValueError, "maximum is 3600|expired"):
            snapshot.verify_candidate(self.manifest, self.archive, self.scratch(), self.epoch - 200 * 86400)

    def test_empty_bucket_bootstrap_only(self):
        self.archive = self.work / "empty"
        self.archive.mkdir()
        self.assertEqual(self.restore()[0], [])
        (self.archive / "partial").touch()
        with self.assertRaisesRegex(snapshot.SnapshotError, "nonempty"):
            self.restore()

    def test_wrong_domain_signer(self):
        self.sign(self.archive, self.epoch, self.subkeys[1])
        with self.assertRaisesRegex(snapshot.SnapshotError, "gpgv"):
            self.restore()

    def test_payload_tamper(self):
        path = next((self.archive / "pool").rglob("*.deb"))
        payload = bytearray(path.read_bytes())
        payload[-1] ^= 1
        path.write_bytes(payload)
        with self.assertRaisesRegex(snapshot.SnapshotError, "signed identity"):
            self.restore()

    def test_signed_state_must_agree_with_control_and_indexes(self):
        self.replace_state(lambda state: state["packages"].pop())
        with self.assertRaisesRegex(snapshot.SnapshotError, "index disagree"):
            self.restore()

    def test_bad_state_schema_or_duplicate_identity(self):
        self.replace_state(lambda state: state["packages"].append(copy.deepcopy(state["packages"][0])))
        with self.assertRaisesRegex(snapshot.SnapshotError, "duplicate"):
            self.restore()

    def test_boolean_schema_rejected(self):
        self.replace_state(lambda state: state.update(schema_version=True))
        with self.assertRaisesRegex(snapshot.SnapshotError, "binding"):
            self.restore()

    def test_ownership_changes_rejected(self):
        self.manifest.write_text(self.manifest.read_text().replace('source_repo = "test/beta"', 'source_repo = "test/other"'))
        with self.assertRaisesRegex(snapshot.SnapshotError, "ownership"):
            self.restore()

    def test_overlapping_ownership_rejected(self):
        self.manifest.write_text(self.manifest.read_text().replace('packages = ["beta"]', 'packages = ["alpha"]'))
        with self.assertRaisesRegex(SystemExit, "ownership overlaps"):
            self.restore()

    def test_control_field_names_are_case_insensitive(self):
        for field in ("package", "pAcKaGe", "PACKAGE"):
            with self.subTest(field=field), self.assertRaisesRegex(SystemExit, "repeated"):
                renderer.parse_fields(f"Package: alpha\n{field}: beta\n", "fixture")

    def test_symlink_rejected(self):
        (self.archive / "linked").symlink_to(self.pool, target_is_directory=True)
        with self.assertRaisesRegex(snapshot.SnapshotError, "link"):
            self.restore()

    def test_candidate_armored_key_and_extra_objects_rejected(self):
        armored = self.archive / "example-archive-keyring.asc"
        original = armored.read_bytes()
        armored.write_bytes(self.run_gpg(["--armor", "--export", self.subkeys[1] + "!"]))
        with self.assertRaisesRegex(snapshot.SnapshotError, "keyrings disagree"):
            snapshot.verify_candidate(self.manifest, self.archive, self.scratch(), self.epoch)
        armored.write_bytes(original)
        (self.archive / "pool/unindexed.deb").write_bytes(b"not indexed")
        with self.assertRaisesRegex(snapshot.SnapshotError, "unindexed"):
            snapshot.verify_candidate(self.manifest, self.archive, self.scratch(), self.epoch)

    def test_same_version_different_bytes(self):
        incoming = self.work / "incoming"
        incoming.mkdir()
        for arch in ("amd64", "arm64"):
            path = self.deb(incoming, "alpha", "1.0", arch)
            build(path, {"Package": "alpha", "Version": "1.0", "Architecture": arch,
                         "Maintainer": "Test <test@example.invalid>", "Description": "different bytes"})
        with self.assertRaisesRegex(snapshot.SnapshotError, "same-version"):
            self.prepare("alpha", incoming)
        self.assertFalse((self.work / "merged").exists())

    def test_rollback_and_arch_removal_rejected(self):
        incoming = self.work / "incoming"
        incoming.mkdir()
        for arch in ("amd64", "arm64"):
            self.deb(incoming, "alpha", "0.9", arch)
        with self.assertRaisesRegex(snapshot.SnapshotError, "roll back"):
            self.prepare("alpha", incoming)
        (incoming / "alpha_0.9_arm64.deb").unlink()
        self.deb(incoming, "alpha", "2.0", "amd64")
        with self.assertRaisesRegex(snapshot.SnapshotError, "architecture"):
            self.prepare("alpha", incoming)

    def plan(self, epoch):
        plan = self.work / "plan.json"
        meta = publication_plan.load(self.manifest)
        meta["publication_epoch"] = epoch
        plan.write_text(json.dumps(dict(meta=meta, entries=publication_plan.plan(self.archive, meta))))
        return plan

    def test_guard_requires_newer_epoch_and_skips_identical_immutable(self):
        _, baseline = self.prepare()
        with self.assertRaisesRegex(snapshot.SnapshotError, "newer"):
            snapshot.guard(self.manifest, self.store(), self.scratch(), baseline, self.plan(self.epoch))
        entries = snapshot.guard(self.manifest, self.store(), self.scratch(), baseline, self.plan(self.epoch + 1))
        self.assertTrue(all(e["skip"] for e in entries if e["phase"] == "pool" or "/by-hash/" in e["key"]))

    def test_generation_race(self):
        _, baseline = self.prepare()
        marker = self.archive / "dists/rolling/InRelease"
        marker.write_bytes(marker.read_bytes() + b"\n")
        with self.assertRaisesRegex(snapshot.SnapshotError, "generation changed"):
            snapshot.guard(self.manifest, self.store(), self.scratch(), baseline, self.plan(self.epoch + 1))
        with self.assertRaisesRegex(snapshot.SnapshotError, "generation changed"):
            snapshot.commit_guard(self.manifest, self.store(), self.scratch(), baseline)

    def test_unindexed_immutable_collision(self):
        _, baseline = self.prepare()
        plan = self.plan(self.epoch + 1)
        payload = self.archive / "pool/retired.deb"
        payload.write_bytes(b"old")
        local = self.work / "replacement.deb"
        local.write_bytes(b"new")
        data = json.loads(plan.read_text())
        data["entries"].append(dict(phase="pool", key="pool/retired.deb", local=str(local), size=3))
        plan.write_text(json.dumps(data))
        with self.assertRaisesRegex(snapshot.SnapshotError, "immutable object collision"):
            snapshot.guard(self.manifest, self.store(), self.scratch(), baseline, plan)

    def test_duplicate_json_and_unsafe_paths(self):
        path = self.work / "bad.json"
        path.write_text('{"x": 1, "x": 2}')
        with self.assertRaisesRegex(snapshot.SnapshotError, "duplicate JSON"):
            snapshot.read_json(path)
        for key in ("../pool/a", "/pool/a", "pool//a", "pool/./a", "pool/a\nkey"):
            with self.subTest(key=key), self.assertRaises(snapshot.SnapshotError):
                snapshot.safe_key(key)

    def test_store_read_errors_are_not_bootstrap(self):
        store = snapshot.Store(self.manifest)
        for message in (b"(AccessDenied)", b"network failure", b"(NoSuchKey)"):
            result = subprocess.CompletedProcess([], 1, b"", message)
            with patch.object(snapshot.subprocess, "run", return_value=result):
                if message == b"(NoSuchKey)":
                    self.assertFalse(store.get("missing", self.work / "absent", 10, optional=True))
                else:
                    with self.assertRaisesRegex(snapshot.SnapshotError, "not a verified absence"):
                        store.get("missing", self.work / "absent", 10, optional=True)

    def test_partial_missing_read_and_oversize_rejected(self):
        store = snapshot.Store(self.manifest)
        target = self.work / "partial"
        target.write_bytes(b"x" * 11)
        for result in (subprocess.CompletedProcess([], 1, b"", b"(NoSuchKey)"),
                       subprocess.CompletedProcess([], 0, b'{"ETag":"abc"}', b"")):
            with patch.object(snapshot.subprocess, "run", return_value=result), self.assertRaises(snapshot.SnapshotError):
                store.get("object", target, 10, optional=True)

    def publisher(self, baseline, remote, **extra):
        fake = self.work / "fake-bin"
        fake.mkdir(exist_ok=True)
        executable = fake / "aws"
        executable.write_text(f'#!/bin/sh\nexec python3 "{ROOT}/tests/fake_s3.py" "$@"\n')
        executable.chmod(0o755)
        env = dict(os.environ, PATH=f"{fake}:{os.environ['PATH']}", R2_ACCESS_KEY_ID="test-only",
                   R2_SECRET_ACCESS_KEY="test-only", APT_TEST_S3_ROOT=str(remote),
                   APT_TEST_S3_LOG=str(self.work / "puts"), **extra)
        return subprocess.run(["bash", str(ROOT / "scripts/publish-archive.sh"), "--manifest", str(self.manifest),
                               "--archive-dir", str(self.archive), "--publication-epoch", str(self.epoch),
                               "--baseline", str(baseline)], env=env, capture_output=True, text=True, timeout=60)

    def test_real_publisher_bootstrap_and_conditional_commit(self):
        remote = self.work / "remote"
        remote.mkdir()
        baseline = self.work / "baseline.json"
        baseline.write_text(json.dumps(dict(schema_version=1, base_url="https://deb.example.invalid", suite="rolling",
                                           inrelease_sha256=None, inrelease_etag=None, publication_epoch=0)))
        result = self.publisher(baseline, remote)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.work / "puts").read_text().splitlines()]
        for args in calls:
            key = args[args.index("--key") + 1]
            if key.startswith("pool/") or "/by-hash/" in key or key.endswith("/InRelease"):
                self.assertIn("--if-none-match", args)
        self.assertEqual(snapshot.sha256(remote / "dists/rolling/InRelease"),
                         snapshot.sha256(self.archive / "dists/rolling/InRelease"))
        _, old = snapshot.restore(self.manifest, snapshot.DirectoryStore(remote), self.scratch())
        baseline.write_text(json.dumps(dict(schema_version=1, base_url="https://deb.example.invalid", suite="rolling", **old)))
        self.epoch += 1
        self.archive = self.make_archive(self.pool, "second", self.epoch)
        (self.work / "puts").write_text("")
        result = self.publisher(baseline, remote)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.work / "puts").read_text().splitlines()]
        self.assertTrue(all(not args[args.index("--key") + 1].startswith("pool/") for args in calls))
        self.assertIn("--if-match", calls[-1])

    def test_real_publisher_denial_and_tamper_write_nothing(self):
        _, baseline = self.prepare()
        for extra in ({"APT_TEST_S3_DENY": "1"}, {}):
            # With no denial the non-monotonic candidate fails before any PUT.
            result = self.publisher(baseline, self.archive, **extra)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.work / "puts").exists())
        path = self.archive / "dists/rolling/Release"
        path.write_bytes(path.read_bytes() + b"tamper\n")
        result = self.publisher(baseline, self.archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / "puts").exists())


if __name__ == "__main__":
    unittest.main()
