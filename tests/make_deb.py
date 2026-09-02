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

AR_MAGIC = b"!<arch>\n"


def tar_bytes(members: list[tuple[str, bytes, str]]) -> bytes:
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as archive:
        for name, payload, kind in members:
            info = tarfile.TarInfo(name)
            info.mtime = 0
            info.mode = 0o644
            if kind == "regular":
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))
            elif kind == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = "elsewhere"
                archive.addfile(info)
            else:
                raise ValueError(f"unknown tar fixture kind: {kind}")
    return raw.getvalue()


def gzip_bytes(payload: bytes) -> bytes:
    out = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", mtime=0, fileobj=out) as handle:
        handle.write(payload)
    return out.getvalue()


def tar_gz(members: dict[str, bytes]) -> bytes:
    entries = [(name, payload, "regular") for name, payload in sorted(members.items())]
    return gzip_bytes(tar_bytes(entries))


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


def build(path: Path, fields: dict[str, str], fixture: str = "valid") -> None:
    control = "".join(f"{k}: {v}\n" for k, v in fields.items()).encode("utf-8")
    if fixture == "control-no-newline":
        control = control.rstrip(b"\n")
    elif fixture == "control-nul":
        control += b"\x00"

    control_entries = [("./control", control, "regular")]
    if fixture == "missing-control":
        control_entries = [("./not-control", control, "regular")]
    elif fixture == "duplicate-control":
        control_entries.append(("control", control, "regular"))
    elif fixture == "symlink-control":
        control_entries = [("./control", b"", "symlink")]

    control_member = "control.tar.gz"
    control_payload = gzip_bytes(tar_bytes(control_entries))
    if fixture == "corrupt-control-compression":
        control_payload = b"not a gzip stream"
    elif fixture == "corrupt-control-tar":
        control_payload = gzip_bytes(b"not a tar archive")

    members = [
        ("debian-binary", b"2.0\n"),
        (control_member, control_payload),
        ("data.tar.gz", tar_gz({"./usr/share/doc/x": b"x\n"})),
    ]
    if fixture == "duplicate-ar-member":
        members.append(("data.tar.gz", b"duplicate"))
    if fixture == "bad-ar-padding":
        members.append(("odd", b"x"))

    if fixture == "truncated-ar-header":
        payload = AR_MAGIC + b"short"
    else:
        payload = ar(members)
    if fixture == "bad-ar-magic":
        payload = b"BROKEN!!" + payload[len(b"BROKEN!!"):]
    elif fixture == "bad-ar-padding":
        payload = payload[:-1] + b"X"
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
    parser.add_argument(
        "--fixture",
        choices=(
            "valid", "bad-ar-magic", "truncated-ar-header", "duplicate-ar-member",
            "bad-ar-padding", "corrupt-control-compression", "corrupt-control-tar",
            "missing-control", "duplicate-control", "symlink-control",
            "control-no-newline", "control-nul",
        ),
        default="valid",
        help="emit one deliberately malformed package structure for a negative test",
    )
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
    build(args.out, fields, args.fixture)


if __name__ == "__main__":
    main()
