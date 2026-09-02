#!/usr/bin/env python3
"""Compute the ordered upload plan for one signed archive.

Kept separate from the upload itself on purpose: the order and the mapping from
local path to object key is arithmetic, so it is testable without credentials
and without a network. The uploader is a thin layer over this.

Objects first, metadata last. The pool and the indexes go up before Release and
its signatures, because the reverse leaves a window in which signed metadata
points at packages that are not there yet.

Nothing here sets Cache-Control. Those headers come from the zone's Cache Rules;
a second source of truth on the object would be one too many.
"""

from __future__ import annotations

import argparse
import json
import sys
import tomllib
from pathlib import Path
from typing import NoReturn

# The keyring is served at domain level, not per project, so it lands in the
# bucket root while everything else lands under the project prefix.
PHASES = ("keyring", "pool", "indexes", "release")

RELEASE_FILES = ("Release", "Release.gpg", "InRelease")

CONTENT_TYPES = {
    ".deb": "application/vnd.debian.binary-package",
    ".gz": "application/gzip",
    ".asc": "text/plain; charset=utf-8",
}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"AR140 {message}")


def content_type(path: Path, phase: str) -> str:
    if phase == "keyring":
        # The armoured file is text, the dearmoured one is binary.
        return CONTENT_TYPES.get(path.suffix, "application/pgp-keys")
    if phase == "indexes" and "/by-hash/" in path.as_posix():
        # A by-hash file is a copy of either Packages or Packages.gz under a hex
        # name, so the extension says nothing. Pinned to one value rather than
        # left to a guessing table; apt ignores Content-Type entirely.
        return "application/octet-stream"
    if path.suffix in CONTENT_TYPES:
        return CONTENT_TYPES[path.suffix]
    # Packages, Release, InRelease and Release.gpg are all plain text.
    return "text/plain; charset=utf-8"


def load(manifest: Path, project: str) -> dict:
    try:
        with manifest.open("rb") as handle:
            data = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        fail(f"cannot read {manifest}: {error}")

    def need(section: str, key: str) -> str:
        block = data.get(section)
        if not isinstance(block, dict) or not isinstance(block.get(key), str):
            fail(f"{manifest}: [{section}] {key} must be a string")
        value = block[key]
        if value == "TBD":
            fail(f"{manifest}: [{section}] {key} is still TBD")
        return value

    projects = data.get("projects")
    if not isinstance(projects, list):
        fail(f"{manifest}: [[projects]] is missing")
    matches = [p for p in projects if isinstance(p, dict) and p.get("name") == project]
    if len(matches) != 1:
        known = ", ".join(sorted(str(p.get("name")) for p in projects if isinstance(p, dict)))
        fail(f"{manifest}: project {project!r} is not declared exactly once; declared: {known}")
    prefix = matches[0].get("prefix")
    if not isinstance(prefix, str) or not prefix.startswith("/") or ".." in prefix:
        fail(f"{manifest}: project {project!r} has an unsafe prefix {prefix!r}")

    return {
        "bucket": need("publication", "r2_bucket"),
        "account_id": need("publication", "r2_account_id"),
        "host": need("domain", "host"),
        "base_url": need("domain", "base_url"),
        "keyring_package": need("domain", "keyring_package"),
        "suite": need("release", "suite"),
        "prefix": prefix.lstrip("/"),
    }


def plan(archive: Path, meta: dict) -> list[dict]:
    suite = meta["suite"]
    dists = archive / "dists" / suite
    for name in RELEASE_FILES:
        target = dists / name
        if not target.is_file() or target.is_symlink():
            fail(f"the archive is not signed: {target} is missing")

    entries: list[dict] = []

    def add(phase: str, path: Path, key: str) -> None:
        if path.is_symlink() or not path.is_file():
            fail(f"not a regular file: {path}")
        entries.append({
            "phase": phase,
            "local": path.as_posix(),
            "key": key,
            "content_type": content_type(path, phase),
            "size": path.stat().st_size,
        })

    for suffix in (".asc", ".gpg"):
        keyring = archive / f"{meta['keyring_package']}{suffix}"
        if not keyring.is_file():
            fail(f"the domain keyring is missing: {keyring}")
        add("keyring", keyring, f"{meta['keyring_package']}{suffix}")

    pool = archive / "pool"
    if not pool.is_dir():
        fail(f"the pool is missing: {pool}")
    for path in sorted(p for p in pool.rglob("*") if p.is_file()):
        add("pool", path, f"{meta['prefix']}/{path.relative_to(archive).as_posix()}")

    release_paths = {dists / name for name in RELEASE_FILES}
    for path in sorted(p for p in dists.rglob("*") if p.is_file() and p not in release_paths):
        add("indexes", path, f"{meta['prefix']}/{path.relative_to(archive).as_posix()}")

    # Release last, and InRelease last of all: it is the file apt reads first,
    # so it is the one that must never point forward.
    for name in ("Release", "Release.gpg", "InRelease"):
        path = dists / name
        add("release", path, f"{meta['prefix']}/{path.relative_to(archive).as_posix()}")

    seen: dict[str, str] = {}
    for entry in entries:
        if entry["key"] in seen:
            fail(f"two local files map to one object key {entry['key']}")
        seen[entry["key"]] = entry["local"]
    return entries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--archive-dir", type=Path, required=True)
    parser.add_argument("--format", choices=("tsv", "json"), default="tsv")
    args = parser.parse_args()

    if not args.manifest.is_file() or args.manifest.is_symlink():
        fail(f"manifest must be a regular file: {args.manifest}")
    if not args.archive_dir.is_dir() or args.archive_dir.is_symlink():
        fail(f"archive-dir must be a real directory: {args.archive_dir}")

    meta = load(args.manifest, args.project)
    entries = plan(args.archive_dir.resolve(), meta)

    if args.format == "json":
        json.dump({"meta": meta, "entries": entries}, sys.stdout, indent=1)
        sys.stdout.write("\n")
        return
    for entry in entries:
        print("\t".join((entry["phase"], entry["local"], entry["key"],
                         entry["content_type"], str(entry["size"]))))


if __name__ == "__main__":
    main()
