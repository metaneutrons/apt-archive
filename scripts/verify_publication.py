#!/usr/bin/env python3
"""Verify the complete signed domain graph and every public object, read-only."""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

from domain_snapshot import SnapshotError, require, sha256, verify_candidate
from publication_plan import load, plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--archive-dir", type=Path, required=True)
    parser.add_argument("--publication-epoch", type=int, required=True)
    parser.add_argument("--project")
    parser.add_argument("--base-url")
    parser.add_argument("--local-only", action="store_true")
    args = parser.parse_args()
    meta = load(args.manifest, args.project)
    entries = plan(args.archive_dir, meta)
    with tempfile.TemporaryDirectory(prefix="apt-verify-") as temporary:
        work = Path(temporary)
        verify_candidate(args.manifest, args.archive_dir, work / "candidate", args.publication_epoch)
        if args.local_only:
            print("signed domain candidate verified; no network writes")
            return
        base = args.base_url or meta["base_url"]
        url = urlsplit(base)
        require(base == meta["base_url"] or (url.scheme == "http" and url.hostname == "127.0.0.1"
                and not url.path and not url.username and not url.query and not url.fragment),
                "base override is permitted only for an isolated loopback test server")
        for entry in entries:
            target = work / "download"
            result = subprocess.run(["curl", "--silent", "--show-error", "--fail", "--proto", "=https,http",
                                     "--connect-timeout", "10", "--max-time", "120", "--max-filesize",
                                     str(max(1, entry["size"])), "--output", str(target),
                                     f"{base}/{entry['key']}"], capture_output=True, timeout=130, check=False)
            require(result.returncode == 0, f"cannot fetch bounded public object: {entry['key']}")
            require(target.stat().st_size == entry["size"] and sha256(target) == sha256(Path(entry["local"])),
                    f"published object differs from the verified local file: {entry['key']}")
        print(f"publication verified against {base}: {len(entries)} objects, signed state and complete domain inventory")


if __name__ == "__main__":
    try:
        main()
    except (SnapshotError, OSError, ValueError, KeyError, TypeError, EOFError, subprocess.TimeoutExpired) as error:
        print(f"::error::AR160 publication verification rejected: {error}", file=sys.stderr)
        sys.exit(1)
