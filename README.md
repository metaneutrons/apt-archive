# apt-archive

Builds and signs the APT archives behind `deb.metaneutrons.cc` and
`deb.snapdog.cc`. One repository for every archive domain, one directory per
domain under `domains/`.

Project repositories never upload. They attach their `.deb` files to a GitHub
release with a build provenance attestation; this repository fetches them,
verifies that attestation, renders the archive metadata, signs it, publishes it
to R2 and then checks the public URL against what it just built.

## The trust model

An APT client trusts an archive because of one signature over one file. Being
precise about which file, made with which key, is the whole security argument
here.

**What is signed.** `dists/<suite>/Release` is the only signed object. It lists
every index file of that archive with its SHA256 and SHA512 sum, so a signature
over `Release` transitively covers `Packages` and `Packages.gz`. Each index in
turn lists every package with its own SHA256 and SHA512, which is what covers
the `.deb` files. Nothing else is signed, and nothing else needs to be: a
tampered index or package fails a hash comparison the client makes itself.

`Release` ships in two signed forms. `InRelease` is the clear-signed version
that modern apt fetches, `Release.gpg` the detached signature that older clients
use. Both carry the same bytes underneath.

**What signs it.** A certify-only Ed25519 primary key, kept offline, with one
signing subkey per archive domain. The primary key certifies; it never signs an
archive. Its secret half never leaves the vault, and it is not in this
repository, not in CI and not in any backup that CI can reach.

CI holds nothing but an export of the signing subkeys, per domain in its own
protected environment as `APT_GPG_PRIVATE_KEY`. That this really is a
subkeys-only export is not taken on faith:
[`verify-signing-bundle.sh`](scripts/verify-signing-bundle.sh) checks the
imported material rather than the armor, because an armored block does not show
what is inside it. In the `sec` record of `gpg --with-colons`, field 15 has to
carry a `#`, the marker for a primary key without its secret part. If the `#` is
missing, signing aborts before it starts.

Signing always uses the subkey named in the domain manifest, pinned with a
trailing exclamation mark. Without that pin gpg chooses for itself when several
signing subkeys are present, and the choice is then not the one in the manifest.

**What a client verifies.** With
`Signed-By: /usr/share/keyrings/<domain>-archive-keyring.pgp`, apt checks the
signature on `InRelease` against exactly that keyring and nothing else — not the
system keyring, not a keyserver. The keyring published here is minimised to the
one subkey of that domain, so a compromise of the other domain's subkey does not
extend to this one. From there the client checks each index against its sum in
`Release`, and each package against its sum in the index. Every byte apt
installs is reachable from that one signature.

**What a client cannot verify.** It cannot tell who built the `.deb`, only that
whoever holds the domain subkey published it. The attestation check that binds a
package to a source repository and a workflow identity happens here, in
`fetch-packages.sh`, before the package ever enters the archive. An asset on a
GitHub release only proves that some account was allowed to upload it; the
attestation binds it to a workflow. **Without an attestation the fetch aborts,
it does not warn.**

It also cannot detect that a publication has stopped, beyond the window the
archive itself declares. That window is `Valid-Until`, set to exactly 180 days
after each publication. Once it passes, apt refuses the archive rather than
serving indefinitely old metadata. Refreshing it means re-signing, and
re-signing means a new run.

Finally, it cannot notice a rolled-back archive as long as the signature is
valid and the window is open. `Acquire-By-Hash` narrows that: apt fetches index
files under their checksum, so a cached old index cannot be served against a new
`InRelease`.

## Why this is one central repository

An R2 API token can be restricted to buckets, not to prefixes. If every project
got write access, every project would have write access to the whole archive.
Hence the projects publish nothing themselves.

One bucket per archive domain, named after it, with the custom domain attached
to exactly that bucket. Two hostnames over the same objects would be two
repositories with identical content as far as apt is concerned, and one token
for a shared bucket would be one token for both domains.

For the restriction to a bucket to mean anything, the token pair in an
environment has to be issued for exactly that one bucket. An account-wide pair
satisfies the form of the check and not its purpose.

## Layout

```
domains/
  metaneutrons.cc/manifest.toml   projects, bucket, subkey, base URL
  snapdog.cc/manifest.toml
scripts/                          renderer, fetch, sign, publish, verify
tests/                            five contract suites, 179 assertions
```

The renderer and the workflows are shared and read the manifest. If a domain
ever needs to split off, its directory moves into a new repository without any
code travelling with it.

[`scripts/README.md`](scripts/README.md) documents every stage in detail: what
the renderer rejects, why by-hash is mirrored under every hash, how the
publication order is chosen and what the follow-up check actually proves.

## Decisions

The layout is one archive per project under its own prefix, not a shared
`dists/` with components. A shared archive would have a shared `Valid-Until`
clock, and one neglected project would drag every other one down with it.

`Suite` and `Codename` are `rolling`. In the Debian world `stable` is a term of
art for the current Debian release and is misleading for a rolling archive of
one's own. From the first published stanza onwards this is frozen.

`Acquire-By-Hash` is mandatory, for the reason given above.

`Date` and `Valid-Until` are set afresh on every publication, a re-signature
included, from a publication time created internally immediately beforehand.
Neither a dispatch payload nor a commit timestamp can supply that clock.

There is no cron. GitHub disables scheduled workflows in public repositories
after 60 days without a commit, and only commits count as activity. The trigger
comes from the project after its release, or from an external watchdog asking
for a re-signature, both through `repository_dispatch`.

## Using an archive

```
# /etc/apt/sources.list.d/metaneutrons.sources
Types: deb
URIs: https://deb.metaneutrons.cc/<project>
Suites: rolling
Components: main
Signed-By: /usr/share/keyrings/metaneutrons-archive-keyring.pgp
```

One keyring package per domain. Both subkey fingerprints are published together
with the primary fingerprint, because `gpgv` and `sqv` name the *signing subkey*
in an error, not the primary key — a `NO_PUBKEY` message therefore quotes an ID
that does not appear on the primary.

The binary OpenPGP keyring file carries the same `.pgp` name in the archive and
in the keyring package, so `Signed-By` points at the file the package installs
without any renaming.

A project's `packages` list is exhaustive. Every name in it has to appear at
least once as a matching `.deb` in the stable releases under consideration.
Optional packages are not silently tolerated; if they are ever needed, they get
a manifest field of their own.

## Status

Nothing is published yet. The chain is complete and covered by the contract
suites: `deb.metaneutrons.cc` sits on `deb-metaneutrons-cc`, `deb.snapdog.cc` on
`deb-snapdog-cc`, both manifests carry the verified public fingerprints, and the
protected environments `release-metaneutrons.cc` and `release-snapdog.cc` each
hold the four secrets the workflow needs. The secret primary key stays in the
vault and is in no CI bundle.

What is still missing sits in the source projects. A project becomes publishable
the moment its latest stable release carries the `.deb` files its manifest entry
declares, each with a build provenance attestation. As of 5 September 2026:

| Project | Latest stable release | `.deb` assets | Attested |
| --- | --- | --- | --- |
| `aros-tools` | none | — | — |
| `devserial` | `devserial-v0.1.9` | 2 | yes |
| `ugos-cli` | `v0.12.0` | 2 | yes |
| `bups` | `v0.1.1` | none | — |
| `snapdog` | `v0.27.1` | 4 | no |

This table goes stale on its own. The authoritative answer is a fetch run:
`scripts/fetch-packages.sh` names exactly what is missing and aborts rather than
warning.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for commit conventions, hooks and the
two rules that hold without exception on any path that publishes.

Security reports go through Private Vulnerability Reporting, not through issues;
see [`SECURITY.md`](SECURITY.md).

## License

Copyright © 2026 Fabian Schmieder.

This repository is licensed under the GNU General Public License version 3; see
[`LICENSE`](LICENSE).
