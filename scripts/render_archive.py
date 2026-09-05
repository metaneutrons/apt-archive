#!/usr/bin/env python3
"""Render a deterministic APT archive for all published projects of one domain.

Only the Python standard library is used, so the rendered bytes do not depend
on the package set of a GitHub-hosted runner.  Signing happens outside; this
module never touches a key.

The Debian control reader is carried over from `metaneutrons/aros-tools`
(`scripts/release/render-apt-metadata.py`), whose sole author relicensed it for
use here.  Everything above it is new: that renderer handled exactly one
package, one version, one hard-coded pool path and exactly two architectures.

Layout produced under `--output-dir`, the domain root (no project prefix):

    pool/<component>/<p>/<source>/<file>.deb
    dists/<suite>/<component>/binary-<arch>/Packages
    dists/<suite>/<component>/binary-<arch>/Packages.gz
    dists/<suite>/<component>/binary-<arch>/by-hash/<ALG>/<hash>
    dists/<suite>/Release
"""

from __future__ import annotations

import argparse
import bz2
import gzip
import hashlib
import io
import json
import lzma
import os
import functools
import re
import shutil
import tarfile
import tomllib
from pathlib import Path
from typing import BinaryIO, NoReturn

from release_time import MIN_VALID_SECONDS, rfc2822

AR_MAGIC = b"!<arch>\n"
CONTROL_MEMBER = re.compile(r"^(?:\./)?control$")

# Debian policy 5.6.1 and 5.6.12.
PACKAGE_NAME = re.compile(r"^[a-z0-9][a-z0-9+.-]+$")
DEBIAN_VERSION = re.compile(r"^(?:[0-9]+:)?[0-9][A-Za-z0-9.+~:-]*$")
ARCHITECTURE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
SUITE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
COMPONENT = re.compile(r"^[a-z0-9][a-z0-9-]*$")
PROJECT_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{1,63}$")
HEX40 = re.compile(r"^[0-9A-Fa-f]{40}$")
# Anything written into a Release line. A line break in it appends an
# arbitrary further line to the file.
RELEASE_FIELD = re.compile(r"^[\x20-\x7e]+$")

# Bounds against a hostile .deb.  A project release is attested before it gets
# here, but the renderer must not become the weak link if that ever slips.
MAX_DEB_BYTES = 512 * 1024 * 1024
MAX_AR_MEMBERS = 64
MAX_CONTROL_ARCHIVE_BYTES = 8 * 1024 * 1024
MAX_CONTROL_TAR_BYTES = 16 * 1024 * 1024
MAX_TAR_MEMBERS = 1_024
MAX_TAR_REGULAR_BYTES = 16 * 1024 * 1024
MAX_CONTROL_BYTES = 256 * 1024
COPY_CHUNK_BYTES = 64 * 1024

# Written into Release and mirrored into by-hash.  MD5Sum and SHA1 are omitted
# on purpose; every apt that reaches an Ed25519-signed archive understands
# SHA256, and publishing a broken hash is worse than publishing none.
RELEASE_HASHES = (("SHA256", "sha256"), ("SHA512", "sha512"))

# Packages.xz is deliberately absent.  Its determinism depends on the liblzma
# build, and the saving on an index of a few kilobytes does not pay for that.
INDEX_NAMES = ("Packages", "Packages.gz")
COMPUTED_CONTROL_FIELDS = frozenset(("filename", "size", "sha256", "sha512"))

def fail(message: str) -> NoReturn:
    raise SystemExit(f"AR100 {message}")


def read_exact(source: BinaryIO, size: int, description: str) -> bytes:
    data = source.read(size)
    if len(data) != size:
        fail(f"Debian package has a truncated {description}")
    return data


def ar_control_member(package: Path) -> tuple[str, bytes]:
    """Return the name and raw bytes of the single control.tar* ar member."""
    try:
        package_size = package.stat().st_size
    except OSError as error:
        fail(f"cannot inspect {package.name}: {error}")
    if package_size <= len(AR_MAGIC) or package_size > MAX_DEB_BYTES:
        fail(f"{package.name} size is outside the safe range (maximum {MAX_DEB_BYTES} bytes)")

    candidates: list[tuple[str, bytes]] = []
    names: set[str] = set()
    with package.open("rb") as source:
        if read_exact(source, len(AR_MAGIC), "ar archive signature") != AR_MAGIC:
            fail(f"{package.name} has no ar archive signature")
        member_count = 0
        while source.tell() < package_size:
            member_count += 1
            if member_count > MAX_AR_MEMBERS:
                fail(f"{package.name} has too many ar members")
            header = read_exact(source, 60, "ar member header")
            if header[58:60] != b"`\n":
                fail(f"{package.name} has a malformed ar member header")
            try:
                raw_name = header[:16].decode("ascii", "strict").strip()
                member_size = int(header[48:58].decode("ascii", "strict").strip())
            except (UnicodeDecodeError, ValueError):
                fail(f"{package.name} has a malformed ar member identity or size")
            if member_size < 0 or source.tell() + member_size + (member_size % 2) > package_size:
                fail(f"{package.name} has a truncated ar member")

            name = raw_name[:-1] if raw_name.endswith("/") else raw_name
            payload_size = member_size
            if name.startswith("#1/"):
                try:
                    name_length = int(name[3:])
                except ValueError:
                    fail(f"{package.name} has a malformed extended ar member name")
                if name_length <= 0 or name_length > member_size:
                    fail(f"{package.name} has an unsafe extended ar member name")
                try:
                    name = read_exact(source, name_length, "extended ar member name").decode(
                        "utf-8", "strict"
                    )
                except UnicodeDecodeError:
                    fail(f"{package.name} has a non-UTF-8 extended ar member name")
                payload_size -= name_length
            if not name or name in names:
                fail(f"{package.name} repeats or omits an ar member name: {name!r}")
            names.add(name)

            if name.startswith("control.tar"):
                if payload_size > MAX_CONTROL_ARCHIVE_BYTES:
                    fail(
                        f"{package.name} control archive exceeds "
                        f"{MAX_CONTROL_ARCHIVE_BYTES} bytes"
                    )
                candidates.append((name, read_exact(source, payload_size, "control archive")))
            else:
                source.seek(payload_size, os.SEEK_CUR)

            if member_size % 2:
                if read_exact(source, 1, "ar member padding") != b"\n":
                    fail(f"{package.name} has malformed ar member padding")

    if len(candidates) != 1:
        fail(f"{package.name} must contain exactly one control.tar member")
    return candidates[0]


def decompress_control(name: str, payload: bytes, package: Path) -> bytes:
    compressed = io.BytesIO(payload)
    try:
        if name.endswith(".gz"):
            source: BinaryIO = gzip.GzipFile(fileobj=compressed, mode="rb")
        elif name.endswith(".xz"):
            source = lzma.LZMAFile(compressed, mode="rb")
        elif name.endswith(".bz2"):
            source = bz2.BZ2File(compressed, mode="rb")
        elif name == "control.tar":
            source = compressed
        else:
            fail(f"unsupported Debian control compression in {name!r}")

        output = io.BytesIO()
        while True:
            block = source.read(COPY_CHUNK_BYTES)
            if not block:
                break
            if output.tell() + len(block) > MAX_CONTROL_TAR_BYTES:
                fail(
                    f"{package.name} expanded control archive exceeds "
                    f"{MAX_CONTROL_TAR_BYTES} bytes"
                )
            output.write(block)
        source.close()
        return output.getvalue()
    except (EOFError, OSError, lzma.LZMAError) as error:
        fail(f"cannot decompress control metadata from {package.name}: {error}")


def control_text(package: Path) -> str:
    name, compressed = ar_control_member(package)
    payload = decompress_control(name, compressed, package)
    control_matches = 0
    control_data: bytes | None = None
    regular_bytes = 0
    member_count = 0
    try:
        with tarfile.open(fileobj=io.BytesIO(payload), mode="r|") as archive:
            for member in archive:
                member_count += 1
                if member_count > MAX_TAR_MEMBERS:
                    fail(f"{package.name} control archive has too many members")
                if member.isfile():
                    regular_bytes += member.size
                    if regular_bytes > MAX_TAR_REGULAR_BYTES:
                        fail(
                            f"{package.name} control archive regular-file total exceeds "
                            f"{MAX_TAR_REGULAR_BYTES} bytes"
                        )
                if CONTROL_MEMBER.fullmatch(member.name):
                    control_matches += 1
                    if not member.isfile() or member.size > MAX_CONTROL_BYTES:
                        fail(f"{package.name} control metadata is not a bounded regular file")
                    extracted = archive.extractfile(member)
                    if extracted is None:
                        fail(f"cannot read control metadata from {package.name}")
                    control_data = extracted.read(MAX_CONTROL_BYTES + 1)
                    if len(control_data) != member.size or len(control_data) > MAX_CONTROL_BYTES:
                        fail(f"{package.name} control metadata exceeds its declared safe size")
    except (tarfile.TarError, OSError) as error:
        fail(f"cannot parse control archive from {package.name}: {error}")
    if control_matches != 1 or control_data is None:
        fail(f"{package.name} must contain exactly one regular control file")
    try:
        text = control_data.decode("utf-8", "strict").replace("\r\n", "\n")
    except UnicodeDecodeError:
        fail(f"{package.name} has non-UTF-8 Debian control metadata")
    if "\x00" in text or not text.endswith("\n"):
        fail(f"{package.name} has unsafe Debian control metadata")
    return text.rstrip("\n")


def parse_fields(text: str, origin: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    current: str | None = None
    for line in text.splitlines():
        if line.startswith((" ", "\t")):
            if current is None:
                fail(f"{origin}: Debian control continuation has no field")
            fields[current] += "\n" + line
            continue
        if ": " not in line:
            fail(f"{origin}: Debian control metadata has a malformed field")
        current, value = line.split(": ", 1)
        if not re.fullmatch(r"[A-Za-z0-9-]+", current) or current in fields:
            fail(f"{origin}: Debian control field is unsafe or repeated: {current!r}")
        fields[current] = value
    return fields


class Domain:
    """The parts of a domain manifest the renderer needs, already validated."""

    def __init__(self, data: dict, project_name: str | None, manifest_path: Path) -> None:
        # Types are checked, never coerced. `bool("false")` is True and
        # `int(True)` is 1, so coercing manifest input would turn a typo into a
        # silently wrong archive: a disabled acquire_by_hash read as enabled,
        # or a 180-day validity read as one day.
        def need(section: str, key: str, kind: type):
            block = data.get(section)
            if not isinstance(block, dict) or key not in block:
                fail(f"{manifest_path}: [{section}] is missing {key}")
            value = block[key]
            # bool is a subclass of int; an explicit bool must not pass as int.
            if not isinstance(value, kind) or (kind is int and isinstance(value, bool)):
                fail(
                    f"{manifest_path}: [{section}] {key} must be "
                    f"{kind.__name__}, not {type(value).__name__}"
                )
            return value

        def need_strings(section: str, key: str) -> list[str]:
            value = need(section, key, list)
            for item in value:
                if not isinstance(item, str):
                    fail(
                        f"{manifest_path}: [{section}] {key} must hold only "
                        f"strings, found {type(item).__name__}"
                    )
            return value

        if project_name is not None and not PROJECT_NAME.fullmatch(project_name):
            fail(f"{manifest_path}: project name must be one safe printable field")

        self.origin = need("domain", "origin", str)
        self.host = need("domain", "host", str)
        self.base_url = need("domain", "base_url", str)
        self.suite = need("release", "suite", str)
        self.codename = need("release", "codename", str)
        self.components = need_strings("release", "components")
        self.architectures = need_strings("release", "architectures")
        self.acquire_by_hash = need("release", "acquire_by_hash", bool)
        self.valid_until_days = need("release", "valid_until_days", int)
        if not re.fullmatch(r"[a-z0-9]+(?:[.-][a-z0-9]+)*", self.host):
            fail(f"{manifest_path}: host must be a DNS hostname")
        if self.base_url != f"https://{self.host}":
            fail(f"{manifest_path}: base_url must be the HTTPS domain root without a path")
        if need("domain", "layout", str) != "shared-root-v1":
            fail(f"{manifest_path}: domain layout must be shared-root-v1")

        # Every value reaching a Release line must be one printable line.
        for label, value in (("origin", self.origin), ("host", self.host)):
            if not RELEASE_FIELD.fullmatch(value):
                fail(f"{manifest_path}: [domain] {label} must be one printable line")

        if not SUITE.fullmatch(self.suite) or not SUITE.fullmatch(self.codename):
            fail(f"{manifest_path}: suite and codename must be safe path components")
        if not self.components or not all(COMPONENT.fullmatch(c) for c in self.components):
            fail(f"{manifest_path}: components must be non-empty and safe")
        if len(set(self.components)) != len(self.components):
            fail(f"{manifest_path}: components repeat")
        if not self.architectures or not all(ARCHITECTURE.fullmatch(a) for a in self.architectures):
            fail(f"{manifest_path}: architectures must be non-empty and safe")
        if len(set(self.architectures)) != len(self.architectures):
            fail(f"{manifest_path}: architectures repeat")
        if "all" in self.architectures:
            # `all` is not a binary architecture.  Such packages are merged into
            # every declared binary index instead of getting one of their own.
            fail(f"{manifest_path}: 'all' must not be declared as an architecture")
        if not self.acquire_by_hash:
            # The whole point of the layout.  Refusing here keeps a silent
            # downgrade from reaching a published archive.
            fail(f"{manifest_path}: acquire_by_hash must stay enabled")
        if self.valid_until_days < 1:
            fail(f"{manifest_path}: valid_until_days must be positive")

        projects = data.get("projects")
        if not isinstance(projects, list) or not projects:
            fail(f"{manifest_path}: [[projects]] is missing")
        self.projects: dict[str, dict] = {}
        self.owners: dict[str, dict] = {}
        for project in projects:
            if not isinstance(project, dict):
                fail(f"{manifest_path}: project must be a table")
            name = project.get("name")
            if not isinstance(name, str) or not PROJECT_NAME.fullmatch(name):
                fail(f"{manifest_path}: project name must be one safe printable field")
            if name in self.projects:
                fail(f"{manifest_path}: project {name!r} is not declared exactly once")
            if "prefix" in project:
                fail(f"{manifest_path}: project prefixes are forbidden in shared-root-v1")
            packages = project.get("packages")
            if (not isinstance(packages, list) or not packages
                    or not all(isinstance(p, str) and PACKAGE_NAME.fullmatch(p) for p in packages)):
                fail(f"{manifest_path}: project {name!r} declares no safe package names")
            repo = project.get("source_repo")
            if not isinstance(repo, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
                fail(f"{manifest_path}: project {name!r} must declare a safe source_repo")
            self.projects[name] = project
            for package in packages:
                if package in self.owners:
                    fail(f"{manifest_path}: package ownership overlaps for {package!r}")
                self.owners[package] = project
        if project_name is not None and project_name not in self.projects:
            known = sorted(str(p.get("name")) for p in projects if isinstance(p, dict))
            fail(f"{manifest_path}: project {project_name!r} is not declared exactly once; "
                 f"declared: {', '.join(known)}")
        self.project = project_name or self.origin
        self.packages = (self.projects[project_name]["packages"] if project_name is not None
                         else sorted(self.owners))

    @property
    def base_path(self) -> str:
        return self.host


def load_domain(manifest_path: Path, project: str | None = None) -> Domain:
    try:
        with manifest_path.open("rb") as handle:
            data = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        fail(f"cannot read {manifest_path}: {error}")
    return Domain(data, project, manifest_path)


@functools.lru_cache(maxsize=None)
def digests(path: Path, size: int, algorithms: tuple[str, ...]) -> dict[str, str]:
    """Hash a file once for every algorithm at the same time.

    One pass per algorithm would read each .deb twice, and `Architecture: all`
    packages appear in every binary index, so the same file would be read again
    per architecture. `size` is part of the key so a changed file cannot hit a
    stale entry.
    """
    values = {name: hashlib.new(name) for name in algorithms}
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            for value in values.values():
                value.update(block)
    return {name: value.hexdigest() for name, value in values.items()}


def digest(path: Path, algorithm: str) -> str:
    return digests(path, path.stat().st_size, (algorithm,))[algorithm]


def pool_letter(source_name: str) -> str:
    """Debian's pool fan-out directory: `libfoo` goes to `libf`, `foo` to `f`."""
    return source_name[:4] if source_name.startswith("lib") else source_name[:1]


class Binary:
    """One .deb, its parsed control stanza and its place in the pool."""

    def __init__(self, path: Path, domain: Domain, component: str) -> None:
        self.source_path = path
        fields = parse_fields(control_text(path), path.name)
        self.fields = fields

        computed = sorted(
            name for name in fields if name.casefold() in COMPUTED_CONTROL_FIELDS
        )
        if computed:
            fail(
                f"{path.name} supplies archive-computed control fields: "
                f"{', '.join(computed)}"
            )

        for required in ("Package", "Version", "Architecture"):
            if required not in fields:
                fail(f"{path.name} has no {required} field")
        self.package = fields["Package"]
        self.version = fields["Version"]
        self.architecture = fields["Architecture"]

        if not PACKAGE_NAME.fullmatch(self.package):
            fail(f"{path.name} has an unsafe package name {self.package!r}")
        if not DEBIAN_VERSION.fullmatch(self.version):
            fail(f"{path.name} has an unsafe version {self.version!r}")
        if not ARCHITECTURE.fullmatch(self.architecture):
            fail(f"{path.name} has an unsafe architecture {self.architecture!r}")

        # Package identity has to match the manifest.  A project that quietly
        # renames its binary would otherwise land in the archive unnoticed.
        if self.package not in domain.packages:
            fail(
                f"{path.name} declares package {self.package!r}, which project "
                f"{domain.project!r} does not list; declared: {', '.join(domain.packages)}"
            )
        if self.architecture != "all" and self.architecture not in domain.architectures:
            fail(
                f"{path.name} declares architecture {self.architecture!r}, which the "
                f"domain does not serve; declared: {', '.join(domain.architectures)}"
            )

        source = fields.get("Source", self.package).split(" ", 1)[0]
        if not PACKAGE_NAME.fullmatch(source):
            fail(f"{path.name} has an unsafe source name {source!r}")
        self.pool_path = (
            f"pool/{component}/{pool_letter(source)}/{source}/"
            f"{self.package}_{self.version}_{self.architecture}.deb"
        )

    @property
    def identity(self) -> tuple[str, str, str]:
        return (self.package, self.version, self.architecture)


def collect(pool_dir: Path, domain: Domain, component: str) -> list[Binary]:
    debs = sorted(p for p in pool_dir.iterdir() if p.suffix == ".deb")
    if not debs:
        fail(f"{pool_dir} contains no .deb file")
    binaries: list[Binary] = []
    seen: dict[tuple[str, str, str], str] = {}
    for path in debs:
        if path.is_symlink() or not path.is_file():
            fail(f"{path} is not a regular file")
        binary = Binary(path, domain, component)
        previous = seen.get(binary.identity)
        if previous is not None:
            # Two files claiming the same identity would give the index two
            # stanzas for one package and apt an arbitrary winner.
            fail(
                f"{path.name} and {previous} both provide "
                f"{binary.package} {binary.version} {binary.architecture}"
            )
        seen[binary.identity] = path.name
        binaries.append(binary)
    portable = {(binary.package, binary.version) for binary in binaries
                if binary.architecture == "all"}
    native = {(binary.package, binary.version) for binary in binaries
              if binary.architecture != "all"}
    conflicts = sorted(portable & native)
    if conflicts:
        package, version = conflicts[0]
        fail(
            f"{package} {version} is provided both as Architecture: all and "
            "as a native package"
        )
    return binaries


def stanza(binary: Binary, archive_root: Path) -> bytes:
    pool_file = archive_root / binary.pool_path
    size = pool_file.stat().st_size
    computed = digests(pool_file, size, tuple(a for _, a in RELEASE_HASHES))
    lines = [f"{name}: {value}" for name, value in binary.fields.items()]
    lines.append(f"Filename: {binary.pool_path}")
    lines.append(f"Size: {size}")
    for label, algorithm in RELEASE_HASHES:
        lines.append(f"{label}: {computed[algorithm]}")
    return ("\n".join(lines) + "\n").encode("utf-8")


def write_gzip(source: Path, target: Path) -> None:
    # mtime=0 and an empty filename keep the member header free of anything
    # that changes between two runs.
    with source.open("rb") as reader, target.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", compresslevel=9, mtime=0, fileobj=raw) as out:
            shutil.copyfileobj(reader, out)
    os.chmod(target, 0o644)


def write_by_hash(index: Path, directory: Path) -> None:
    """Mirror one index under every hash Release announces.

    Writing only the strongest hash would be a gamble on which one a given apt
    asks for.  The files are a few kilobytes; the redundancy is free.
    """
    for label, algorithm in RELEASE_HASHES:
        target_dir = directory / "by-hash" / label
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / digest(index, algorithm)
        shutil.copyfile(index, target)
        os.chmod(target, 0o644)


def render(
    domain: Domain,
    binaries: list[Binary],
    archive_root: Path,
    component: str,
    epoch: int,
) -> None:
    for binary in binaries:
        target = archive_root / binary.pool_path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(binary.source_path, target)
        os.chmod(target, 0o644)

    dists = archive_root / "dists" / domain.suite
    dists.mkdir(parents=True, exist_ok=True)
    state = dists / "archive-state.json"
    state.write_text(json.dumps({
        "schema_version": 1,
        "base_url": domain.base_url,
        "suite": domain.suite,
        "component": component,
        "architectures": domain.architectures,
        "packages": [{
            "project": domain.owners[b.package]["name"],
            "source_repo": domain.owners[b.package]["source_repo"],
            "package": b.package, "version": b.version, "architecture": b.architecture,
            "filename": b.pool_path,
            "size": (archive_root / b.pool_path).stat().st_size,
            "sha256": digest(archive_root / b.pool_path, "sha256"),
        } for b in sorted(binaries, key=lambda b: b.identity)],
    }, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.chmod(state, 0o644)
    write_by_hash(state, dists)
    # `Architecture: all` belongs in every binary index, not in one of its own.
    portable = [b for b in binaries if b.architecture == "all"]
    for architecture in domain.architectures:
        native = [b for b in binaries if b.architecture == architecture]
        selected = sorted(native + portable, key=lambda b: (b.package, b.version))

        binary_dir = dists / component / f"binary-{architecture}"
        binary_dir.mkdir(parents=True, exist_ok=True)
        packages = binary_dir / "Packages"
        # An architecture the domain declares but no package serves still needs
        # an index; apt reports a missing one as an error.
        packages.write_bytes(b"\n".join(stanza(b, archive_root) for b in selected))
        os.chmod(packages, 0o644)
        write_gzip(packages, binary_dir / "Packages.gz")
        for name in INDEX_NAMES:
            write_by_hash(binary_dir / name, binary_dir)

    indexes = sorted(
        path for path in dists.rglob("*")
        if path.is_file() and "by-hash" not in path.relative_to(dists).parts
    )
    header = [
        f"Origin: {domain.origin}",
        f"Label: {domain.origin}",
        f"Suite: {domain.suite}",
        f"Codename: {domain.codename}",
        f"Architectures: {' '.join(domain.architectures)}",
        f"Components: {component}",
        "Acquire-By-Hash: yes",
        f"Description: Packages for {domain.base_path}",
        f"Date: {rfc2822(epoch)}",
        f"Valid-Until: {rfc2822(epoch + domain.valid_until_days * 86400)}",
    ]
    sections: list[str] = []
    for label, algorithm in RELEASE_HASHES:
        sections.append(f"{label}:")
        for index in indexes:
            relative = index.relative_to(dists).as_posix()
            sections.append(f" {digest(index, algorithm)} {index.stat().st_size:16d} {relative}")
    release = dists / "Release"
    release.write_text("\n".join((*header, *sections)) + "\n", encoding="utf-8")
    os.chmod(release, 0o644)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Render the complete domain APT archive from a verified merged pool."
    )
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--project", help="optional request identity, not an index filter")
    parser.add_argument("--pool-dir", type=Path, required=True,
                        help="flat directory holding every .deb to publish")
    parser.add_argument("--output-dir", type=Path, required=True,
                        help="must not exist; becomes the archive root")
    parser.add_argument("--publication-epoch", type=int, required=True,
                        help="publication time used for Date and Valid-Until")
    parser.add_argument("--component", default=None,
                        help="defaults to the manifest's single component")
    args = parser.parse_args()

    if args.publication_epoch <= 0:
        fail("publication-epoch must be a positive integer")
    if not args.manifest.is_file() or args.manifest.is_symlink():
        fail(f"manifest must be a regular file: {args.manifest}")
    if not args.pool_dir.is_dir() or args.pool_dir.is_symlink():
        fail(f"pool-dir must be a real directory: {args.pool_dir}")
    if args.output_dir.exists() or args.output_dir.is_symlink():
        fail(f"output-dir must be a new path: {args.output_dir}")

    if args.project:
        load_domain(args.manifest, args.project)
    domain = load_domain(args.manifest)
    if domain.valid_until_days * 86400 < MIN_VALID_SECONDS:
        fail("valid_until_days must cover at least a week")

    component = args.component or (
        domain.components[0] if len(domain.components) == 1 else None
    )
    if component is None:
        fail(f"--component is required; the domain declares {', '.join(domain.components)}")
    if component not in domain.components:
        fail(f"component {component!r} is not declared; declared: {', '.join(domain.components)}")

    binaries = collect(args.pool_dir, domain, component)

    args.output_dir.parent.mkdir(parents=True, exist_ok=True)
    args.output_dir.mkdir(mode=0o755)
    render(domain, binaries, args.output_dir, component, args.publication_epoch)

    served = sorted({b.package for b in binaries})
    print(
        f"{domain.base_path}: {len(binaries)} package files, "
        f"{len(served)} packages ({', '.join(served)}), "
        f"suite {domain.suite}, component {component}"
    )


if __name__ == "__main__":
    main()
