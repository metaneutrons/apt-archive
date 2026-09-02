#!/usr/bin/env python3
"""Build a minimal but real .deb without dpkg, so tests run on any host.

A .deb is an ar archive of debian-binary, control.tar.gz and data.tar.gz, in
that order.  Nothing here is clever; it exists so the renderer is tested
against actual package bytes rather than a mock.
"""

from __future__ import annotations

import argparse
import gzip
import io
import tarfile
from pathlib import Path


def tar_gz(members: dict[str, bytes]) -> bytes:
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as archive:
        for name, payload in sorted(members.items()):
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            info.mtime = 0
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(payload))
    out = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", mtime=0, fileobj=out) as handle:
        handle.write(raw.getvalue())
    return out.getvalue()


def ar(members: list[tuple[str, bytes]]) -> bytes:
    out = io.BytesIO()
    out.write(b"!<arch>\n")
    for name, payload in members:
        header = (
            f"{name:<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(payload):<10}"
        ).encode("ascii") + b"`\n"
        assert len(header) == 60, len(header)
        out.write(header)
        out.write(payload)
        if len(payload) % 2:
            out.write(b"\n")
    return out.getvalue()


def build(path: Path, fields: dict[str, str]) -> None:
    control = "".join(f"{k}: {v}\n" for k, v in fields.items()).encode("utf-8")
    payload = ar([
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", tar_gz({"./control": control})),
        ("data.tar.gz", tar_gz({"./usr/share/doc/x": b"x\n"})),
    ])
    path.write_bytes(payload)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--source", default=None)
    parser.add_argument("--extra", action="append", default=[],
                        help="additional control field as Name=Value")
    args = parser.parse_args()
    fields = {
        "Package": args.package,
        "Version": args.version,
        "Architecture": args.architecture,
        "Maintainer": "Test <test@example.invalid>",
        "Description": "test package",
    }
    if args.source:
        fields["Source"] = args.source
    for item in args.extra:
        name, _, value = item.partition("=")
        fields[name] = value
    args.out.parent.mkdir(parents=True, exist_ok=True)
    build(args.out, fields)


if __name__ == "__main__":
    main()
