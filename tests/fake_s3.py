#!/usr/bin/env python3
"""Filesystem S3 protocol double, reachable only through explicit test env."""

import hashlib
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["APT_TEST_S3_ROOT"])
assert root.is_dir() and not root.is_symlink()
args = sys.argv[1:]
assert "s3api" in args and "https://00000000000000000000000000000000.r2.cloudflarestorage.com" in args
operation = next(a for a in args if a in ("head-bucket", "get-object", "head-object", "list-objects-v2", "put-object"))


def field(name):
    return args[args.index(name) + 1]


def fail(code):
    print(f"An error occurred ({code})", file=sys.stderr)
    sys.exit(1)


def etag(path):
    return '"' + hashlib.sha256(path.read_bytes()).hexdigest() + '"'


if os.environ.get("APT_TEST_S3_DENY") == "1":
    fail("AccessDenied")
if operation == "head-bucket":
    sys.exit(0)
if operation == "list-objects-v2":
    objects = [p for p in root.rglob("*") if p.is_file()]
    print(json.dumps(dict(KeyCount=min(1, len(objects)), IsTruncated=len(objects) > 1)))
    sys.exit(0)
key = field("--key")
assert not key.startswith("/") and ".." not in key.split("/")
path = root / key
if operation in ("get-object", "head-object"):
    if not path.is_file():
        fail("NoSuchKey")
    if operation == "get-object":
        data = path.read_bytes()
        if "--range" in args:
            data = data[:int(field("--range").split("-")[1]) + 1]
        Path(args[-1]).write_bytes(data)
    print(json.dumps(dict(ETag=etag(path), ContentLength=path.stat().st_size)))
else:
    with Path(os.environ["APT_TEST_S3_LOG"]).open("a") as log:
        log.write(json.dumps(args) + "\n")
    if "--if-none-match" in args and path.exists():
        fail("PreconditionFailed")
    if "--if-match" in args and (not path.exists() or etag(path) != field("--if-match")):
        fail("PreconditionFailed")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(Path(field("--body")).read_bytes())
    print(json.dumps(dict(ETag=etag(path))))
