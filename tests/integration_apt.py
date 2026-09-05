#!/usr/bin/env python3
"""Qualify real APT in disposable containers, without production credentials."""

import subprocess
import sys
import uuid

from test_domain_snapshot import Transactions, ROOT


def run(args):
    subprocess.run(args, check=True, timeout=180)


def main():
    Transactions.setUpClass()
    fixture = Transactions("test_signed_roundtrip_and_candidate")
    try:
        fixture.setUp()
        name = "apt-render-test-" + uuid.uuid4().hex[:12]
        created = False
        try:
            run(["docker", "create", "--name", name, "--network", "none",
                 "python:3.14.2-slim-bookworm@sha256:e87711ef5c86aaeaa7031718a69db79d334d94c545c709583f651b8185870941",
                 "python3", "/scripts/render_archive.py", "--manifest", "/manifest.toml",
                 "--pool-dir", "/pool", "--output-dir", "/result", "--publication-epoch", str(fixture.epoch)])
            created = True
            for source, target in ((ROOT / "scripts", "/scripts"), (fixture.manifest, "/manifest.toml"), (fixture.pool, "/pool")):
                run(["docker", "cp", str(source), name + ":" + target])
            run(["docker", "start", "--attach", name])
            out = fixture.work / "container-rendered"
            run(["docker", "cp", name + ":/result", str(out)])
            for path in out.rglob("*"):
                if path.is_file() and path.read_bytes() != (fixture.archive / path.relative_to(out)).read_bytes():
                    raise RuntimeError(f"container renderer differs: {path.relative_to(out)}")
            print("Pinned renderer and local two-project output are byte-identical.", flush=True)
        finally:
            if created:
                run(["docker", "rm", "--force", name])
        # Copy, rather than bind-mount, so this works with remote Docker daemons
        # and macOS backends that do not share the checkout volume.
        for image in sys.argv[1:] or [
                "debian:bookworm@sha256:6ebd97fa83deb272194a2cf015b3d26a4d538e9ad3a7a79d544c8af5b0a01443",
                "debian:13-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258"]:
            name = "apt-domain-test-" + uuid.uuid4().hex[:12]
            created = False
            try:
                run(["docker", "create", "--name", name, "--network", "none", image, "bash", "/probe.sh"])
                created = True
                run(["docker", "cp", str(fixture.archive), name + ":/archive"])
                run(["docker", "cp", str(ROOT / "tests/apt_client.sh"), name + ":/probe.sh"])
                run(["docker", "start", "--attach", name])
                status = subprocess.check_output(["docker", "inspect", "--format", "{{.State.ExitCode}}", name], timeout=30)
                if status.strip() != b"0":
                    raise RuntimeError(f"APT client qualification failed for {image}")
            finally:
                if created:
                    run(["docker", "rm", "--force", name])
    finally:
        fixture.doCleanups()
        Transactions.tearDownClass()


if __name__ == "__main__":
    main()
