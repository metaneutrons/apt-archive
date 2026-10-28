# Rust archive production

`apt-archive-tool` is the sole implementation of manifest validation, release
selection, Debian metadata parsing, rendering, snapshot recovery, upload
planning and publication verification. The shell scripts retain only process
orchestration for GitHub, GPG, AWS and curl.

Build it once from the repository root:

```bash
cargo build --release --locked
export AR_ARCHIVE_TOOL="$PWD/target/release/apt-archive-tool"
```

The checked-in `rust-toolchain.toml` and `Cargo.lock` are the complete Rust input
pin. No container or interpreter is downloaded at runtime.

## Transaction

One domain has one signed inventory and one publication clock.

1. `fetch-packages.sh` selects stable, attested release assets.
2. For `ami-rust`, selection is stricter: the newest stable release must carry
   `channel-handoff.json` plus its Sigstore bundle. Cosign verifies the fixed
   protected-workflow identity. The Rust tool then requires the signed APT
   identities to equal the public GitHub Release sizes and SHA-256 digests.
   Package bytes are downloaded unchanged; the archive never rebuilds an SDK.
3. `snapshot-prepare` authenticates the last `InRelease` directly from R2,
   restores every signed index and retained package, rejects rollback and
   same-version replacement, merges the new import and applies the manifest's
   retention window. An empty request performs a metadata-only refresh.
   A manifest-pinned `--retire-project` request removes only the exact declared
   inventory, cannot import packages and leaves physical objects untouched.
4. `render-archive.sh` creates the pool, indexes, both by-hash trees,
   `archive-state.json`, landing page and unsigned `Release`.
5. `sign-archive.sh` verifies the subkey-only signing bundle and creates
   `Release.gpg`, `InRelease` and the minimal domain keyring.
6. `publish-archive.sh` verifies the complete local trust graph, checks the
   restored generation and immutable-object collisions, uploads objects before
   metadata and commits `InRelease` last with an ETag condition.
7. `verify-publication.sh` downloads every public object with bounded reads and
   requires byte identity with the signed candidate.

Multiple object PUTs are not atomic. A failed run may leave unreferenced pool
or by-hash objects. Never delete or overwrite them to force a retry. Prepare a
fresh transaction from the last valid `InRelease`. If the marker is absent in a
nonempty bucket, stop for explicit recovery.

## Renderer contract

The input pool contains every retained `.deb`. Package ownership is declared in
the domain manifest. The Rust reader accepts `control.tar`, `.gz`, `.xz`,
`.bz2` and `.zst`, with bounded archive and control sizes. It rejects:

- undeclared package names or architectures;
- duplicate package/version/architecture identities;
- the same version as both native and `Architecture: all`;
- unsafe Debian fields and caller-supplied computed index fields;
- overlapping ownership, disabled by-hash or an existing output directory.

The pure-Rust gzip implementation has deterministic headers and locked crate
inputs. Equal pool bytes and publication epoch therefore produce equal archive
bytes across supported build hosts.

## Commands

```bash
scripts/fetch-packages.sh \
  --manifest domains/metaneutrons.cc/manifest.toml \
  --project ami-rust --pool-dir /new/incoming

target/release/apt-archive-tool snapshot-prepare \
  --manifest domains/metaneutrons.cc/manifest.toml \
  --project ami-rust --incoming-pool /new/incoming \
  --output-pool /new/pool --baseline /new/baseline.json

# One-shot reset declared under [[retirements]] in the manifest:
target/release/apt-archive-tool snapshot-prepare \
  --manifest domains/metaneutrons.cc/manifest.toml \
  --retire-project ami-rust \
  --output-pool /new/pool --baseline /new/baseline.json

scripts/render-archive.sh \
  --manifest domains/metaneutrons.cc/manifest.toml \
  --pool-dir /new/pool --output-dir /new/archive \
  --publication-epoch 1700000000

scripts/publish-archive.sh \
  --manifest domains/metaneutrons.cc/manifest.toml \
  --archive-dir /new/archive --baseline /new/baseline.json \
  --publication-epoch 1700000000 --preflight
```

`--preflight` performs all local, bucket, generation and immutable-object
checks and writes nothing.

## Local acceptance

```bash
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```

The Rust contract test builds real zstd-compressed Debian packages, renders and
signs a two-architecture archive with a throwaway Ed25519 key, restores and
verifies the complete candidate and proves that a changed package is rejected.
A second contract checks the exact signed ami-rust channel handoff.
