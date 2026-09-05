#!/usr/bin/env python3
"""Restore a signed domain snapshot, merge one import, and guard publication.

The object store is authoritative (not a potentially stale CDN). No remote
write occurs here. A missing commit marker is bootstrap only in an empty
bucket; a partial or legacy archive requires explicit operator recovery.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib

from publication_target import load_target
from release_time import validate_release_time
from render_archive import Binary, collect, load_domain, stanza

MIB = 1024 * 1024
MAX_STATE = 16 * MIB
MAX_PACKAGES = 4096
MAX_TOTAL = 16 * 1024 * MIB


class SnapshotError(ValueError):
    """A domain transaction cannot safely proceed."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SnapshotError(message)


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read_json(path: Path, limit: int = MAX_STATE):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= limit,
            "JSON input is not a bounded regular file")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate JSON field")
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique,
                      parse_constant=lambda _: (_ for _ in ()).throw(SnapshotError("non-finite JSON value")))


def safe_key(key: str) -> str:
    require(isinstance(key, str) and not key.startswith("/")
            and str(PurePosixPath(key)) == key and bool(key)
            and all(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+~:-]*", p)
                    and p not in (".", "..") for p in key.split("/")),
            f"unsafe object key: {key!r}")
    return key


def run(args: list[str]) -> bytes:
    result = subprocess.run(args, capture_output=True, timeout=180, check=False)
    require(result.returncode == 0, f"{Path(args[0]).name} rejected snapshot verification")
    return result.stdout


class Store:
    """Bounded R2 reads; tests provide an in-memory/file implementation."""

    def __init__(self, manifest: Path):
        bucket, account = load_target(manifest)
        self.args = ["aws", "s3api", "--endpoint-url",
                     f"https://{account}.r2.cloudflarestorage.com"]
        self.bucket = bucket
        self.etags = {}

    def get(self, key: str, target: Path, limit: int, *, optional: bool = False) -> bool:
        safe_key(key)
        target.parent.mkdir(parents=True, exist_ok=True)
        require(type(limit) is int and 0 <= limit <= 512 * MIB, "invalid object read limit")
        result = subprocess.run(self.args + ["get-object", "--bucket", self.bucket,
                                "--key", key, "--range", f"bytes=0-{max(1, limit)}", str(target)],
                                capture_output=True, timeout=180, check=False)
        # S3 answers InvalidRange for a truly empty object. A bounded, read-only
        # HEAD distinguishes this case from an arbitrary error; no fallback on
        # authorization or network failures.
        if result.returncode and b"(InvalidRange)" in result.stderr:
            head = run(self.args + ["head-object", "--bucket", self.bucket, "--key", key])
            require(type(json.loads(head).get("ContentLength")) is int
                    and json.loads(head)["ContentLength"] == 0, "invalid range on a nonempty object")
            require(not target.exists(), "failed range read left a partial object")
            target.touch()
            result = subprocess.CompletedProcess(self.args, 0, head, b"")
        if result.returncode:
            missing = re.search(rb"\((NoSuchKey|404)\)", result.stderr) is not None
            require(optional and missing, f"cannot read object {key} (not a verified absence)")
            require(not target.exists(), f"failed read left a partial object: {key}")
            return False
        require(target.is_file() and not target.is_symlink() and target.stat().st_size <= limit,
                f"object {key} is missing, unsafe or oversized")
        etag = json.loads(result.stdout).get("ETag")
        require(isinstance(etag, str) and re.fullmatch(r'"[a-zA-Z0-9-]+"', etag) is not None,
                "object has no safe ETag")
        self.etags[key] = etag
        return True

    def empty(self) -> bool:
        result = run(self.args + ["list-objects-v2", "--bucket", self.bucket,
                                 "--max-keys", "1", "--no-paginate"])
        data = json.loads(result)
        require(isinstance(data, dict) and type(data.get("KeyCount")) is int
                and data["KeyCount"] in (0, 1) and type(data.get("IsTruncated")) is bool,
                "bucket listing has no KeyCount")
        return data["KeyCount"] == 0 and not data["IsTruncated"] and not data.get("Contents")


def binding(manifest: Path) -> dict:
    require(manifest.is_file() and not manifest.is_symlink(), "manifest must be a regular file")
    with manifest.open("rb") as handle:
        data = tomllib.load(handle)
    for field in ("primary_fingerprint", "signing_subkey"):
        require(re.fullmatch(r"[0-9A-F]{40}", data["signing"][field]) is not None,
                f"invalid signing {field}")
    safe_key(data["domain"]["keyring_package"] + ".pgp")
    return data


class DirectoryStore:
    """Same verifier for an isolated candidate; never follow a tree symlink."""

    def __init__(self, root: Path):
        require(root.is_dir() and not root.is_symlink(), "archive root must be a real directory")
        self.root, self.etags = root, {}
        require(not any(p.is_symlink() or not (p.is_file() or p.is_dir()) for p in root.rglob("*")),
                "archive contains a link or nonregular object")

    def get(self, key, target, limit, *, optional=False):
        source = self.root / safe_key(key)
        if optional and not source.exists():
            return False
        require(source.is_file() and not source.is_symlink() and source.stat().st_size <= limit,
                f"missing, unsafe or oversized local object: {key}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        self.etags[key] = '"' + sha256(source) + '"'
        return True

    def empty(self):
        return not any(self.root.iterdir())


def verify_candidate(manifest: Path, root: Path, work: Path, epoch: int) -> None:
    """Close the signed candidate graph before its first public mutation."""
    store = DirectoryStore(root)
    binaries, baseline = restore(manifest, store, work)
    require(bool(binaries) and baseline["publication_epoch"] == epoch,
            "candidate signature does not equal publication epoch")
    domain, data = load_domain(manifest), binding(manifest)
    suite = root / "dists" / domain.suite
    require((work / "Release").read_bytes() == (suite / "Release").read_bytes(),
            "candidate Release differs from signed InRelease")
    validate_release_time(manifest, suite / "Release", epoch, max_age_seconds=3600)
    status = run(["gpgv", "--homedir", str(work / "gnupg"), "--keyring", str(work / "keyring.pgp"),
                  "--status-fd", "1", str(suite / "Release.gpg"), str(suite / "Release")]).decode()
    valid = [line.split() for line in status.splitlines() if line.startswith("[GNUPG:] VALIDSIG ")]
    require(len(valid) == 1 and valid[0][2] == data["signing"]["signing_subkey"]
            and valid[0][-1] == data["signing"]["primary_fingerprint"] and int(valid[0][4]) == epoch,
            "detached signature differs from the domain publication")
    for index in (work / "indexes/SHA256").rglob("*"):
        if index.is_file():
            require(index.read_bytes() == (suite / index.relative_to(work / "indexes/SHA256")).read_bytes(),
                    "mutable index differs from its signed immutable identity")
    expected = {b.pool_path for b in binaries}
    expected.update(data["domain"]["keyring_package"] + suffix for suffix in (".asc", ".pgp"))
    expected.update(f"dists/{domain.suite}/{name}" for name in ("Release", "Release.gpg", "InRelease"))
    for index in (work / "indexes/SHA256").rglob("*"):
        if not index.is_file():
            continue
        relative = index.relative_to(work / "indexes/SHA256")
        expected.add(f"dists/{domain.suite}/{relative}")
        for algorithm in ("SHA256", "SHA512"):
            checksum = hashlib.new(algorithm.lower(), index.read_bytes()).hexdigest()
            expected.add(f"dists/{domain.suite}/{relative.parent}/by-hash/{algorithm}/{checksum}".replace("/./", "/"))
    actual = {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()}
    require(actual == expected, "candidate tree contains missing or unindexed objects")


def verified_release(manifest: Path, store: Store, work: Path) -> tuple[dict, dict] | None:
    """Verify the pinned signer before accepting any previous state or payload."""
    domain = load_domain(manifest)
    data = binding(manifest)
    suite = f"dists/{domain.suite}"
    inrelease = work / "InRelease"
    if not store.get(f"{suite}/InRelease", inrelease, 4 * MIB, optional=True):
        require(store.empty(), "InRelease absent in a nonempty bucket; explicit recovery required")
        return None
    key = work / "keyring.pgp"
    store.get(data["domain"]["keyring_package"] + ".pgp", key, MIB)
    home = work / "gnupg"
    home.mkdir(mode=0o700)
    rows = run(["gpg", "--no-options", "--batch", "--no-autostart", "--homedir", str(home),
                "--with-colons", "--show-keys", "--fingerprint", str(key)]).decode().splitlines()
    primary, subkeys = [], []
    destination = None
    for row in rows:
        fields = row.split(":")
        require(fields[0] not in ("sec", "ssb"), "public keyring contains secret material")
        if fields[0] in ("pub", "sub"):
            require(fields[1] not in ("r", "e", "d", "i"), "archive key is inactive")
            require(not fields[6] or int(fields[6]) > time.time(), "archive key is expired")
            destination = primary if fields[0] == "pub" else subkeys
        elif fields[0] == "fpr" and destination is not None:
            destination.append(fields[9])
            destination = None
    signing = data["signing"]
    require(primary == [signing["primary_fingerprint"]] and subkeys == [signing["signing_subkey"]],
            "archive keyring differs from the pinned domain trust anchor")
    status = run(["gpgv", "--homedir", str(home), "--keyring", str(key),
                  "--status-fd", "1", str(inrelease)]).decode().splitlines()
    valid = [line.split() for line in status if line.startswith("[GNUPG:] VALIDSIG ")]
    require(len(valid) == 1 and valid[0][2] == signing["signing_subkey"]
            and valid[0][-1] == signing["primary_fingerprint"], "unexpected snapshot signer")
    epoch = int(valid[0][4])
    require(0 < epoch <= time.time(), "snapshot signature time is in the future")
    release = work / "Release"
    run(["gpg", "--no-options", "--batch", "--no-autostart", "--homedir", str(home),
         "--no-default-keyring", "--keyring", str(key), "--output", str(release),
         "--decrypt", str(inrelease)])
    # Expired metadata is recoverable, unlike an invalid signature or a future
    # date. Check the old validity interval at its own publication time.
    validate_release_time(manifest, release, epoch, now_epoch=epoch)
    hashes = {"SHA256": {}, "SHA512": {}}
    headers = {}
    section = None
    for line in release.read_text().splitlines():
        if not line.startswith(" "):
            label, value = line.split(":", 1)
            require(label not in headers, "duplicate signed Release field")
            headers[label] = value.strip()
            section = label if label in hashes else None
        elif section:
            parts = line.split()
            require(len(parts) == 3, "malformed signed hash row")
            digest, size, key_path = parts
            safe_key(key_path)
            length = 64 if section == "SHA256" else 128
            require(re.fullmatch(rf"[0-9a-f]{{{length}}}", digest) is not None
                    and size.isdigit() and 0 <= int(size) <= MAX_STATE and key_path not in hashes[section],
                    "invalid or duplicate signed hash identity")
            hashes[section][key_path] = (digest, int(size))
        else:
            require(False, "unexpected signed Release continuation")
    for field, expected in {"Origin": domain.origin, "Label": domain.origin,
                            "Suite": domain.suite, "Codename": domain.codename,
                            "Architectures": " ".join(domain.architectures),
                            "Components": " ".join(domain.components), "Acquire-By-Hash": "yes"}.items():
        require(headers.get(field) == expected, f"signed Release {field} changed")
    expected_paths = {f"{domain.components[0]}/binary-{arch}/{name}"
                      for arch in domain.architectures for name in ("Packages", "Packages.gz")}
    expected_paths.add("archive-state.json")
    for algorithm in hashes:
        require(set(hashes[algorithm]) == expected_paths, "signed domain inventory is incomplete or unexpected")
        for key_path, (digest, size) in hashes[algorithm].items():
            target = work / "indexes" / algorithm / key_path
            parent = str(PurePosixPath(key_path).parent)
            by_hash = f"{suite}/" + (parent + "/" if parent != "." else "")
            store.get(f"{by_hash}by-hash/{algorithm}/{digest}", target, max(1, size))
            with target.open("rb") as stream:
                measured = hashlib.file_digest(stream, algorithm.lower()).hexdigest()
            require(target.stat().st_size == size and measured == digest, "signed index bytes changed")
            if algorithm == "SHA512":
                require(target.read_bytes() == (work / "indexes/SHA256" / key_path).read_bytes(),
                        "signed index hash algorithms disagree")
    state_file = work / "indexes/SHA256/archive-state.json"
    state = read_json(state_file)
    require(type(state) is dict and set(state) == {"schema_version", "base_url", "suite", "architectures", "component", "packages"}
            and type(state.get("schema_version")) is int and state["schema_version"] == 1
            and state.get("base_url") == domain.base_url and state.get("suite") == domain.suite
            and state.get("architectures") == domain.architectures
            and domain.components == [state.get("component")], "snapshot domain binding changed")
    return state, {"inrelease_sha256": sha256(inrelease), "publication_epoch": epoch,
                   "inrelease_etag": store.etags[f"{suite}/InRelease"]}


def restore(manifest: Path, store: Store, work: Path) -> tuple[list[Binary], dict]:
    domain = load_domain(manifest)
    require(len(domain.components) == 1, "shared domain requires exactly one component")
    previous = verified_release(manifest, store, work)
    if previous is None:
        return [], {"inrelease_sha256": None, "publication_epoch": 0, "inrelease_etag": None}
    state, baseline = previous
    rows = state.get("packages")
    require(isinstance(rows, list) and 0 < len(rows) <= MAX_PACKAGES, "invalid snapshot inventory")
    result, seen, total = [], set(), 0
    for number, row in enumerate(rows):
        require(isinstance(row, dict) and set(row) == {"project", "source_repo", "package", "version",
                                                     "architecture", "filename", "size", "sha256"},
                "invalid snapshot package row")
        require(all(isinstance(row[field], str) for field in row if field != "size")
                and re.fullmatch(r"[0-9a-f]{64}", row["sha256"]), "invalid snapshot package fields")
        owner = domain.owners.get(row.get("package"))
        require(owner is not None and owner["name"] == row.get("project")
                and owner["source_repo"] == row.get("source_repo"),
                "published package ownership removed or reassigned; explicit migration required")
        filename = safe_key(row["filename"])
        require(filename.startswith("pool/") and filename not in seen, "duplicate or non-pool payload")
        seen.add(filename)
        size = row["size"]
        require(type(size) is int and 0 < size <= 512 * MIB, "invalid snapshot payload size")
        total += size
        require(total <= MAX_TOTAL, "snapshot exceeds the aggregate payload bound")
        package = work / "payloads" / filename
        store.get(filename, package, size)
        require(package.stat().st_size == size and sha256(package) == row["sha256"],
                f"retained payload differs from signed identity: {filename}")
        binary = Binary(package, domain, state["component"])
        require(binary.pool_path == filename
                and binary.identity == (row["package"], row["version"], row["architecture"]),
                f"retained payload control identity changed: {filename}")
        result.append(binary)
    require(len({b.identity for b in result}) == len(result), "duplicate snapshot package identity")
    for arch in domain.architectures:
        selected = sorted((b for b in result if b.architecture in (arch, "all")),
                          key=lambda b: (b.package, b.version))
        expected = b"\n".join(stanza(b, work / "payloads") for b in selected)
        path = work / "indexes/SHA256" / state["component"] / f"binary-{arch}"
        require((path / "Packages").read_bytes() == expected, "signed state and package index disagree")
        with gzip.open(path / "Packages.gz", "rb") as stream:
            require(stream.read(MAX_STATE + 1) == expected, "compressed package index disagrees or is oversized")
    return result, baseline


def prepare(manifest: Path, store: Store, work: Path, project: str | None,
            incoming: Path | None, output: Path, baseline_file: Path) -> None:
    require(not output.exists() and not output.is_symlink(), "output pool must be a new path")
    require(not baseline_file.exists() and not baseline_file.is_symlink(), "baseline must be a new path")
    domain = load_domain(manifest)
    require((project is None) == (incoming is None), "project and incoming pool must be supplied together")
    prior, baseline = restore(manifest, store, work)
    current = []
    if project is not None:
        selected = load_domain(manifest, project)
        require(incoming.is_dir() and not incoming.is_symlink(), "incoming pool must be a real directory")
        current = collect(incoming, selected, domain.components[0])
        require({b.package for b in current} == set(selected.packages), "incoming package set is incomplete")
    old_by_id = {b.identity: b for b in prior}
    for binary in current:
        old = old_by_id.get(binary.identity)
        require(old is None or (sha256(old.source_path) == sha256(binary.source_path)
                               and old.pool_path == binary.pool_path),
                f"same-version payload changed: {binary.pool_path}")
    # Debian, not lexical/semver ordering (epochs, revisions and tildes matter).
    # A refresh must not silently roll a package back if GitHub loses a release.
    for old in prior:
        if domain.owners[old.package]["name"] != project:
            continue
        candidates = [b for b in current if b.package == old.package
                      and b.architecture == old.architecture]
        require(bool(candidates), "incoming import removed a published package architecture")
        results = [subprocess.run(["dpkg", "--compare-versions", b.version, "ge", old.version],
                                  capture_output=True, timeout=10, check=False) for b in candidates]
        require(all(r.returncode in (0, 1) for r in results), "cannot compare Debian versions")
        require(any(r.returncode == 0 for r in results), "incoming import would roll back a published version")
    merged = [b for b in prior if domain.owners[b.package]["name"] != project] + current
    require(bool(merged), "cannot refresh an empty archive; import a project first")
    require(len(merged) <= MAX_PACKAGES and sum(b.source_path.stat().st_size for b in merged) <= MAX_TOTAL,
            "candidate exceeds the domain inventory bounds")
    staging = work / "merged"
    staging.mkdir()
    for binary in merged:
        target = staging / f"{binary.package}_{binary.version}_{binary.architecture}.deb"
        require(not target.exists(), "merged pool has duplicate package identities")
        shutil.copyfile(binary.source_path, target)
    collect(staging, domain, domain.components[0])  # includes all/native conflict check
    output.parent.mkdir(parents=True, exist_ok=True)
    os.replace(staging, output)
    baseline_file.write_text(json.dumps({"schema_version": 1, "base_url": domain.base_url,
                                         "suite": domain.suite, **baseline}) + "\n")
    print(f"prepared {len(merged)} domain payloads; retained {len(merged) - len(current)}, imported {len(current)}")


def guard(manifest: Path, store: Store, work: Path, baseline_file: Path, plan_file: Path) -> list[dict]:
    domain = load_domain(manifest)
    baseline = read_json(baseline_file, MIB)
    require(baseline.get("schema_version") == 1 and baseline.get("base_url") == domain.base_url
            and baseline.get("suite") == domain.suite, "baseline does not belong to this domain")
    current = work / "current-InRelease"
    exists = store.get(f"dists/{domain.suite}/InRelease", current, 4 * MIB, optional=True)
    require((sha256(current) if exists else None) == baseline["inrelease_sha256"],
            "published generation changed since restore; re-prepare the entire transaction")
    require(exists or store.empty(), "bootstrap bucket changed since restore")
    plan = read_json(plan_file)
    require(type(baseline.get("publication_epoch")) is int, "invalid baseline clock")
    candidate_epoch = plan["meta"]["publication_epoch"]
    require(type(candidate_epoch) is int and candidate_epoch > baseline["publication_epoch"],
            "candidate publication epoch must be newer than the authenticated baseline")
    entries = plan["entries"]
    # Check EVERY immutable object before the first write, including versions
    # no longer indexed but still retained in the bucket. Never replace bytes
    # under an existing pool identity or by-hash name.
    for number, entry in enumerate(entries):
        entry["skip"] = False
        if entry["phase"] == "pool" or "/by-hash/" in entry["key"]:
            local = Path(entry["local"])
            previous = work / f"object-{number}"
            exists = store.get(entry["key"], previous, entry["size"], optional=True)
            if exists:
                require(previous.stat().st_size == entry["size"] and sha256(previous) == sha256(local),
                        f"immutable object collision: {entry['key']}")
                entry["skip"] = True
    return entries


def commit_guard(manifest: Path, store: Store, work: Path, baseline_file: Path) -> str | None:
    domain = load_domain(manifest)
    baseline = read_json(baseline_file, MIB)
    require(baseline.get("base_url") == domain.base_url and baseline.get("suite") == domain.suite,
            "baseline does not belong to this domain")
    key = f"dists/{domain.suite}/InRelease"
    current = work / "InRelease"
    exists = store.get(key, current, 4 * MIB, optional=True)
    require((sha256(current) if exists else None) == baseline["inrelease_sha256"],
            "published generation changed before commit")
    if exists:
        require(store.etags[key] == baseline["inrelease_etag"], "generation ETag changed before commit")
        return store.etags[key]
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("operation", choices=("prepare", "guard", "commit-guard"))
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--project")
    parser.add_argument("--incoming-pool", type=Path)
    parser.add_argument("--output-pool", type=Path)
    parser.add_argument("--plan", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="apt-domain-") as temporary:
        store, work = Store(args.manifest), Path(temporary)
        if args.operation == "prepare":
            require(args.output_pool is not None, "prepare requires output-pool")
            prepare(args.manifest, store, work, args.project, args.incoming_pool,
                    args.output_pool, args.baseline)
        elif args.operation == "guard":
            require(args.plan is not None, "guard requires plan")
            for entry in guard(args.manifest, store, work, args.baseline, args.plan):
                if not entry["skip"]:
                    print("\t".join((entry["phase"], entry["local"], entry["key"],
                                     entry["content_type"], str(entry["size"]))))
        else:
            print(commit_guard(args.manifest, store, work, args.baseline) or "ABSENT")


if __name__ == "__main__":
    try:
        main()
    except (SnapshotError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print(f"AR190 domain snapshot rejected: {error}", file=sys.stderr)
        sys.exit(1)
