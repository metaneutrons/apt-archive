#!/usr/bin/env python3
"""Pick the .deb assets to publish from a project's releases.

Two stages, both pure functions over JSON on stdin, so the selection is
testable without a network.

`--stage tags` reads `gh release list --json tagName,isDraft,isPrerelease,publishedAt`
and prints the tags worth inspecting. `gh release list` cannot return assets, so
`--stage assets` then reads an array of `gh release view --json tagName,assets`
results for exactly those tags. Filtering first keeps it at one API call per
kept release instead of one per release that ever existed.

Rules, all deliberate:

* Drafts and prereleases are skipped. The archive serves stable versions; a
  prerelease belongs in a separate suite, not silently in `rolling`.
* Only the newest `keep` releases are taken. Rebuilding the pool from every
  release would mean 224 downloads for a project with 56 of them, and the pool
  would grow without bound.
* An asset counts only when its name parses as `<package>_<version>_<arch>.deb`
  and the package is one the manifest declares. A project that renames its
  binary must say so in the manifest first.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import NoReturn

# `<package>_<version>_<arch>.deb`, the canonical Debian binary name.
ASSET = re.compile(
    r"^(?P<package>[a-z0-9][a-z0-9+.-]+)"
    r"_(?P<version>[0-9][A-Za-z0-9.+~:-]*)"
    r"_(?P<arch>[a-z0-9][a-z0-9-]*)\.deb$"
)


def fail(message: str) -> NoReturn:
    raise SystemExit(f"AR170 {message}")


def pick_tags(releases: list, keep: int) -> list[str]:
    stable = [
        r for r in releases
        if isinstance(r, dict) and not r.get("isDraft") and not r.get("isPrerelease")
    ]
    if not stable:
        fail("the project has no stable release")
    # `gh release list` returns newest first, but the order is not part of its
    # contract, so sort explicitly on the publication date.
    stable.sort(key=lambda r: str(r.get("publishedAt") or ""), reverse=True)
    tags: list[str] = []
    for release in stable[:keep]:
        tag = release.get("tagName")
        if not isinstance(tag, str) or not tag:
            fail("a release carries no tag name")
        if "/" in tag or tag.startswith("-"):
            fail(f"unsafe tag name {tag!r}")
        tags.append(tag)
    return tags


def select(releases: list, packages: set[str], architectures: set[str]) -> list[dict]:
    chosen: list[dict] = []
    for release in releases:
        if not isinstance(release, dict):
            fail("the asset listing must hold objects")
        tag = release.get("tagName")
        if not isinstance(tag, str) or not tag:
            fail("a release carries no tag name")
        for asset in release.get("assets") or []:
            name = asset.get("name") if isinstance(asset, dict) else None
            if not isinstance(name, str) or not name.endswith(".deb"):
                continue
            match = ASSET.fullmatch(name)
            if match is None:
                fail(f"{tag}: asset {name!r} is not a canonical Debian binary name")
            if match["package"] not in packages:
                # Not a finding: a release may carry .deb files for packages this
                # project does not publish through the archive.
                continue
            if match["arch"] != "all" and match["arch"] not in architectures:
                continue
            chosen.append({
                "tag": tag,
                "name": name,
                "package": match["package"],
                "version": match["version"],
                "arch": match["arch"],
            })
    if not chosen:
        fail(
            "no stable release carries a .deb for the declared packages "
            f"({', '.join(sorted(packages))})"
        )
    seen: dict[tuple[str, str, str], str] = {}
    for entry in chosen:
        identity = (entry["package"], entry["version"], entry["arch"])
        if identity in seen:
            fail(
                f"{entry['name']} appears in {entry['tag']} and {seen[identity]}; "
                "one identity cannot come from two releases"
            )
        seen[identity] = entry["tag"]
    return chosen


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--stage", choices=("tags", "assets"), required=True)
    parser.add_argument("--packages", help="comma-separated, required for assets")
    parser.add_argument("--architectures", help="comma-separated, required for assets")
    parser.add_argument("--keep", type=int, help="required for tags")
    args = parser.parse_args()

    try:
        releases = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        fail(f"cannot parse the release listing: {error}")
    if not isinstance(releases, list):
        fail("the release listing must be a JSON array")

    if args.stage == "tags":
        if args.keep is None or args.keep < 1:
            fail("--keep must be at least 1")
        for tag in pick_tags(releases, args.keep):
            print(tag)
        return

    if not args.packages or not args.architectures:
        fail("--packages and --architectures are required for --stage assets")
    packages = {p for p in args.packages.split(",") if p}
    architectures = {a for a in args.architectures.split(",") if a}
    if not packages or not architectures:
        fail("--packages and --architectures must not be empty")
    for entry in select(releases, packages, architectures):
        print("\t".join((entry["tag"], entry["name"], entry["package"],
                         entry["version"], entry["arch"])))


if __name__ == "__main__":
    main()
