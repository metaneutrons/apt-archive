#!/usr/bin/env python3
"""Validate the publication clock encoded in an APT Release file."""

from __future__ import annotations

import argparse
import datetime as dt
import time
import tomllib
from email.utils import format_datetime
from pathlib import Path

MIN_VALID_SECONDS = 7 * 24 * 3600


class ReleaseTimeError(ValueError):
    """The Release clock is missing, inconsistent, stale, or implausible."""


def rfc2822(epoch: int) -> str:
    try:
        stamp = dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc)
        return format_datetime(stamp)
    except (OverflowError, OSError, ValueError) as error:
        raise ReleaseTimeError(
            f"publication epoch is outside the supported range: {epoch}"
        ) from error


def valid_until_days(manifest: Path) -> int:
    if not manifest.is_file() or manifest.is_symlink():
        raise ReleaseTimeError(f"manifest must be a regular file: {manifest}")
    try:
        with manifest.open("rb") as handle:
            data = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise ReleaseTimeError(f"cannot read {manifest}: {error}") from error

    release = data.get("release")
    if not isinstance(release, dict):
        raise ReleaseTimeError(f"{manifest}: [release] must be a table")
    value = release.get("valid_until_days")
    if isinstance(value, bool) or not isinstance(value, int):
        raise ReleaseTimeError(
            f"{manifest}: [release] valid_until_days must be int, not {type(value).__name__}"
        )
    if value <= 0:
        raise ReleaseTimeError(f"{manifest}: [release] valid_until_days must be positive")
    if value * 86400 < MIN_VALID_SECONDS:
        raise ReleaseTimeError(
            f"{manifest}: [release] valid_until_days must cover at least a week"
        )
    return value


def one_header(lines: list[str], name: str) -> str:
    prefix = f"{name}:"
    matches = [line for line in lines if line.startswith(prefix)]
    if len(matches) != 1:
        raise ReleaseTimeError(
            f"Release must carry exactly one {name} field, found {len(matches)}"
        )
    return matches[0]


def validate_release_time(
    manifest: Path,
    release: Path,
    publication_epoch: int,
    *,
    now_epoch: int | None = None,
    max_age_seconds: int | None = None,
) -> None:
    if publication_epoch <= 0:
        raise ReleaseTimeError("publication epoch must be a positive integer")
    if max_age_seconds is not None and max_age_seconds < 0:
        raise ReleaseTimeError("max age must not be negative")
    if not release.is_file() or release.is_symlink():
        raise ReleaseTimeError(f"Release must be a regular file: {release}")

    try:
        lines = release.read_text(encoding="utf-8", errors="strict").splitlines()
    except (OSError, UnicodeError) as error:
        raise ReleaseTimeError(f"cannot read {release}: {error}") from error

    days = valid_until_days(manifest)
    try:
        valid_until_epoch = publication_epoch + days * 86400
        expected_date = f"Date: {rfc2822(publication_epoch)}"
        expected_valid_until = f"Valid-Until: {rfc2822(valid_until_epoch)}"
    except OverflowError as error:
        raise ReleaseTimeError("Valid-Until is outside the supported range") from error

    date = one_header(lines, "Date")
    valid_until = one_header(lines, "Valid-Until")
    if date != expected_date:
        raise ReleaseTimeError(
            f"Release Date does not equal publication epoch {publication_epoch}: {date!r}"
        )
    if valid_until != expected_valid_until:
        raise ReleaseTimeError(
            f"Release Valid-Until is not exactly {days} days after publication: {valid_until!r}"
        )

    now = int(time.time()) if now_epoch is None else now_epoch
    if now <= 0:
        raise ReleaseTimeError("current epoch must be a positive integer")
    if publication_epoch > now:
        raise ReleaseTimeError(
            f"publication epoch {publication_epoch} is in the future relative to {now}"
        )
    if max_age_seconds is not None and publication_epoch < now - max_age_seconds:
        age = now - publication_epoch
        raise ReleaseTimeError(
            f"publication epoch is {age} seconds old; maximum is {max_age_seconds}"
        )
    if valid_until_epoch <= now:
        raise ReleaseTimeError(
            f"Release expired at {expected_valid_until.removeprefix('Valid-Until: ')}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--publication-epoch", type=int, required=True)
    parser.add_argument("--max-age-seconds", type=int)
    parser.add_argument(
        "--now-epoch",
        type=int,
        help="override the clock for deterministic contract tests",
    )
    args = parser.parse_args()

    try:
        validate_release_time(
            args.manifest,
            args.release,
            args.publication_epoch,
            now_epoch=args.now_epoch,
            max_age_seconds=args.max_age_seconds,
        )
    except ReleaseTimeError as error:
        raise SystemExit(f"AR120 {error}") from error


if __name__ == "__main__":
    main()
