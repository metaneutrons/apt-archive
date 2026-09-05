#!/usr/bin/env python3
"""Read and validate the Cloudflare R2 target from an archive manifest."""

from __future__ import annotations

import argparse
import re
import tomllib
from pathlib import Path
from typing import NoReturn


ACCOUNT_ID = re.compile(r"^[0-9a-f]{32}$")
BUCKET = re.compile(r"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$")


def fail(message: str) -> NoReturn:
    raise SystemExit(f"AR145 {message}")


def load_target(manifest: Path) -> tuple[str, str]:
    try:
        with manifest.open("rb") as handle:
            data = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        fail(f"cannot read {manifest}: {error}")

    publication = data.get("publication")
    if not isinstance(publication, dict):
        fail(f"{manifest}: [publication] is missing")

    bucket = publication.get("r2_bucket")
    account = publication.get("r2_account_id")
    if not isinstance(bucket, str) or not BUCKET.fullmatch(bucket):
        fail(f"{manifest}: [publication] r2_bucket is malformed")
    if not isinstance(account, str) or not ACCOUNT_ID.fullmatch(account):
        fail(f"{manifest}: [publication] r2_account_id is malformed")
    return bucket, account


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    bucket, account = load_target(args.manifest)
    print(f"{bucket}\t{account}")


if __name__ == "__main__":
    main()
