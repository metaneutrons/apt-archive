# Renderer

From a domain manifest and a directory full of `.deb` files, `render_archive.py`
produces the complete, ready-to-sign archive tree **of one project**. It knows
no network, no key and no Cloudflare API.

```
scripts/render-archive.sh \
  --manifest domains/metaneutrons.cc/manifest.toml \
  --project aros-tools \
  --pool-dir /path/to/all/debs \
  --output-dir /path/to/the/new/archive \
  --publication-epoch 1700000000
```

The result sits under `--output-dir`, the archive root of one project prefix, so
for example `https://deb.metaneutrons.cc/aros-tools`:

```
pool/main/a/aros-tools/aros-tools_1.0.0-1_amd64.deb
dists/rolling/main/binary-amd64/Packages
dists/rolling/main/binary-amd64/Packages.gz
dists/rolling/main/binary-amd64/by-hash/SHA256/<sum>
dists/rolling/main/binary-amd64/by-hash/SHA512/<sum>
dists/rolling/Release
```

## One archive per project

Every project gets its own prefix and thereby its own `Release` file with its
own `Valid-Until` clock. A project without a release for half a year expires
without dragging the others down with it.

## The pool is the input, not one version

`--pool-dir` holds **every** version that is to be published. The renderer
indexes what it finds. That makes a project with one version and a project with
forty-one the same code path.

## Why by-hash under every hash

`Release` names SHA256 and SHA512, and apt asks for the **strongest**, so
`by-hash/SHA512/<sum>`. If that tree is missing, apt falls back without an error
message to the mutable path `Packages.gz`, and by-hash has no effect. Measured
on 1 September 2026 against `debian:bookworm`, apt 2.6.1, with a logging server.
Hence the mirror under every hash named in `Release`; the indexes are a few
kilobytes in size.

`Packages.xz` is deliberately absent. Its bytes depend on the liblzma version,
and the saving on an index of this size does not justify losing determinism.

## What the renderer rejects

Everything that would quietly damage an archive:

- a package name the project does not list in the manifest
- an architecture the domain does not serve
- two files with the same identity of name, version and architecture
- the same package version both as `Architecture: all` and as a native package
- unsafe `Version` or `Source` values, or archive-computed control fields such
  as `Filename`, `Size`, `SHA256` and `SHA512` in the incoming package
- a project name or prefix that is not a safe single-line Release field
- a manifest with `acquire_by_hash` switched off
- an output directory that already exists

## Determinism

Two runs with the same input and the same `--publication-epoch` are
byte-identical; the test suite checks that. A later publication epoch changes
only `Date` and `Valid-Until` in `Release`, and afterwards its signatures; pool,
indexes and by-hash stay the same. In a real publish run the protected target
job creates this epoch itself, immediately before rendering. It comes neither
from the commit nor from a dispatch payload.

`render-archive.sh` runs the renderer in a digest-pinned container without a
network, because otherwise the bytes of `Packages.gz` depend on the host's zlib
version. `AR_RENDER_LOCAL=1` bypasses the container.

## Fetching

```
scripts/fetch-packages.sh --manifest domains/snapdog.cc/manifest.toml \
  --project snapdog --pool-dir <new directory>
```

Needs a `GITHUB_TOKEN` with read access to the source repository, nothing else.
Every file passes two checks before it lands in the pool: its SHA256 against the
digest the release API reports, and `gh attestation verify` against the source
repository.

The second is the trust anchor. It binds the file to a workflow identity, not
merely to an account that is allowed to upload an asset. **Without an
attestation the run aborts, it does not warn.** A project without
`actions/attest-build-provenance` cannot be published this way, and that is
intended.

On 2 September 2026 this applies to `SnapDogRocks/snapdog`: 30 releases, no
attestation. Fetching aborts there and names what is missing.

Drafts and prereleases are skipped; the archives carry stable versions, and a
prerelease would belong in a suite of its own. `keep_versions` in the manifest
limits how many releases land in the pool: without a limit it would grow with
every publication.

`select_assets.py` splits the selection into two stages, both pure functions
over JSON and therefore testable without a network. A run queries the release
listing once, then reads the asset listing once per kept tag, and reads the API
digest again for each asset actually chosen. Per chosen asset there follow one
download and one attestation check. The early tag selection avoids asset queries
for all historical releases; it does not claim that the later digest call goes
away.

## Signing

Beside the rendered `Release`, `sign-archive.sh` produces `InRelease` and
`Release.gpg` as well as the domain keyring in both forms, and checks its result
with `gpgv` against exactly the keyring a client gets.
`verify-signing-bundle.sh` checks the imported material beforehand.

Signing always happens with the subkey from the manifest, pinned by a trailing
exclamation mark. Without it gpg picks one itself where there are several
signing subkeys, and the export delivers all of them instead of the one
belonging to this domain.

Before importing the key the script checks that `Date` equals exactly the
publication epoch it was given, that `Valid-Until` reflects exactly the window
from the manifest, and that the epoch is at most one hour old and not in the
future. The same epoch then drives `gpg --faked-system-time`; the signatures
produced are checked back against that time.

The publication epoch must also not precede the creation of the subkey.
Otherwise gpg does not sign and reports nothing but "unusable secret key"; the
script rejects that by name. The consequence: for a re-signature an old tree is
rendered again with a fresh publication epoch.

## Publication

```
scripts/publish-archive.sh --manifest domains/metaneutrons.cc/manifest.toml \
  --project aros-tools --archive-dir <signed root> \
  --publication-epoch <epoch> [--preflight]
```

Credentials come from `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`, never from
arguments. `--preflight` checks access, the bucket and the plan and writes
nothing. The planner checks the publication time again and aborts on an age of
more than one hour, on values in the future or on diverging Release fields,
before the first upload is attempted.

**Objects first, metadata last.** Four phases in this order: keyring, pool,
indexes, then `Release`, `Release.gpg` and `InRelease`. The other way round
would open a window in which signed metadata point at packages that do not exist
yet. Within a phase the upload runs in parallel, between the phases strictly
sequentially, and the release phase entirely sequentially.

**The keyring sits in the bucket root**, not under the project prefix: it holds
for the domain, not for a project.

**Nothing is ever deleted and nothing is ever synchronised.** Old by-hash files
have to stay for at least one release generation, so that an `apt update` in
flight does not grasp at nothing; a `sync --delete` would remove exactly those.

**No cache headers on the objects.** Those come from the zone's cache rules; a
second source of truth would be one too many.

`publication_plan.py` computes the plan and is separate from the upload, because
the order and the mapping from path to object key is pure computation and stays
checkable without credentials.

## Follow-up check

```
scripts/verify-publication.sh --manifest <manifest> --project <name> \
  --archive-dir <local root> --publication-epoch <epoch> \
  [--base-url <override>]
```

What is checked is what a client receives, not what was uploaded: fetch the
keyring, hold `InRelease` against `gpgv` with it, compare byte for byte against
the local copy, extract the signed plaintext and check publication time,
`Valid-Until` and signature time, check `Packages.gz` per architecture against
the sum from `InRelease`, fetch the same index under its `by-hash/SHA512` path
and compare, and finally resolve every `Filename` entry and compare the package
byte for byte.

## Workflows

`ci.yml` checks shell, Python, the manifests and the five contract suites, and
in a job of its own runs the **container-pinned** renderer against the local
path: the two have to be byte-identical. This path could not be checked on the
development machine, where Docker mounts freshly created directories empty.

`publish.yml` drives fetching, rendering, signing, publication and the follow-up
check. No cron: GitHub switches scheduled workflows off in public repositories
after 60 days without a commit, and this repository is commit-poor. The trigger
comes through `workflow_dispatch` or `repository_dispatch`. Both paths use
nothing but the publication epoch freshly created inside the protected publish
job; a caller or watchdog cannot dictate it. Per domain only one run writes at a
time. `queue: max` keeps up to 100 further requests, so that a new dispatch does
not displace a waiting run of another project of the same domain.

**One environment per domain**, `release-<host>`. The standard names a single
`release`; that holds for a project repository. Here there are two keys and two
buckets, and a run for one domain must not be able to read the other one's
credentials.

The preflight job checks the request, the secrets and the bucket without writing
anything. A `client_payload` comes from outside and reaches the shell through
`env` only, never by interpolation.

## Tests

```
bash tests/test_render_archive.sh
bash tests/test_select_assets.sh
bash tests/test_fetch_packages.sh
bash tests/test_signing.sh
bash tests/test_publication.sh
```

179 assertions, no network to the outside, no real key material and no `dpkg`.
`tests/make_deb.py` builds real `.deb` files with what Python brings along, so
that the tests run against package bytes rather than against a dummy. The
signing tests create a throwaway key in the prescribed shape, and the follow-up
check runs against a local server that serves the tree the way the bucket does.

The rejection path of `publish-archive.sh` really runs through, with a
cryptographically valid but stale version and an AWS stub; the probe shows zero
`put-object` attempts. What is not tested locally is a successful upload of all
phases against real R2, because its credentials exist only as a GitHub secret.
