#!/usr/bin/env bash
# Fetches a project's .deb files from its GitHub releases into a pool directory.
#
#   fetch-packages.sh --manifest domains/<host>/manifest.toml \
#                     --project <name> --pool-dir <new directory>
#
# It needs a GITHUB_TOKEN with read access to the source repository and nothing
# else. No key, no R2.
#
# Every file has to pass two checks before it lands in the pool:
#
#   1  the SHA256 matches what the release API reports
#   2  `gh attestation verify` confirms that the source repository's workflow
#      built it
#
# The second is the actual anchor of trust: it binds the file to a workflow
# identity rather than merely to an account allowed to upload an asset. Without
# an attestation the run aborts rather than warns. A project without
# `actions/attest-build-provenance` therefore cannot be published, and that is
# intended.
set -euo pipefail

fail() { printf '::error::AR180 %s\n' "$*" >&2; exit 1; }

# A `shift 2` without a value aborts silently under `set -e`.
opt_value() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"; }

manifest=''; project=''; pool_dir=''
while (($#)); do
  case "$1" in
    --manifest) opt_value "$@"; manifest=$2; shift 2 ;;
    --project)  opt_value "$@"; project=$2; shift 2 ;;
    --pool-dir) opt_value "$@"; pool_dir=$2; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
for name in manifest project pool_dir; do
  [[ -n "${!name}" ]] || fail "--${name//_/-} is required"
done
for command in gh shasum; do
  command -v "$command" >/dev/null || fail "required command is missing: $command"
done
[[ -f "$manifest" && ! -L "$manifest" ]] || fail 'manifest must be a regular file'
[[ ! -e "$pool_dir" && ! -L "$pool_dir" ]] || fail 'pool-dir must be a new path'

script_root=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
archive_tool=${AR_ARCHIVE_TOOL:-"$script_root/../target/release/apt-archive-tool"}
[[ -x "$archive_tool" && ! -L "$archive_tool" ]] \
  || fail 'the Rust archive tool is missing or unsafe; build it with cargo build --release --locked'

read -r source_repo packages architectures keep < <(
  "$archive_tool" project --manifest "$manifest" --project "$project"
) || fail 'cannot read the project from the manifest'

printf 'fetching from %s, keeping %s stable releases\n' "$source_repo" "$keep"

work=$(mktemp -d /tmp/apt-archive-fetch.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

gh release list -R "$source_repo" --limit 200 \
  --json tagName,isDraft,isPrerelease,publishedAt > "$work/releases.json" \
  || fail "cannot list the releases of $source_repo"
"$archive_tool" select-tags --keep "$keep" < "$work/releases.json" > "$work/tags" \
  || fail 'no usable stable release'

if [[ "$project" == ami-rust ]]; then
  # ami-rust packages are accepted only through the newest release's signed
  # channel handoff. Older qualified versions remain in the authenticated
  # archive snapshot and are pruned by the manifest retention window.
  head -n 1 "$work/tags" > "$work/selected-tags"
  command -v cosign >/dev/null || fail 'cosign is required for the signed ami-rust handoff'
  tag=$(cat "$work/selected-tags")
  version=$(printf '%s' "$tag" | sed 's/^v//')
  [[ -n "$version" && "v$version" == "$tag" ]] || fail "ami-rust tag is not v<version>: $tag"
  gh release download "$tag" -R "$source_repo" \
    --pattern channel-handoff.json --pattern channel-handoff.json.sigstore.json \
    --dir "$work" --clobber >/dev/null \
    || fail "cannot download the signed channel handoff from $tag"
  identity='https://github.com/metaneutrons/ami-rust/.github/workflows/toolchain-release.yml@refs/heads/main'
  cosign verify-blob --offline \
    --bundle "$work/channel-handoff.json.sigstore.json" \
    --certificate-identity "$identity" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    "$work/channel-handoff.json" >/dev/null \
    || fail "channel handoff signature verification failed for $tag"
else
  command cp -f "$work/tags" "$work/selected-tags"
fi
printf '  releases: %s\n' "$(tr '\n' ' ' < "$work/tags")"

# `gh release list` cannot deliver assets, hence one `gh release view` per tag
# chosen. Filter first, then query: otherwise it would be one call per release
# that ever existed.
{
  printf '['
  first=1
  while IFS= read -r tag; do
    [[ "$first" -eq 1 ]] || printf ','
    first=0
    gh release view "$tag" -R "$source_repo" --json tagName,assets \
      || fail "cannot read release $tag"
  done < "$work/selected-tags"
  printf ']'
} > "$work/assets.json"

if [[ "$project" == ami-rust ]]; then
  "$archive_tool" handoff-select --manifest "$manifest" --project "$project" \
    --handoff "$work/channel-handoff.json" --version "$version" \
    < "$work/assets.json" > "$work/chosen" \
    || fail 'the signed handoff does not match the public ami-rust release'
else
  "$archive_tool" select-assets --packages "$packages" \
    --architectures "$architectures" < "$work/assets.json" > "$work/chosen" \
    || fail 'no asset matches the declared packages'
fi
printf '  assets:   %s\n' "$(wc -l < "$work/chosen" | tr -d ' ')"

mkdir -p "$pool_dir"
while IFS=$'\t' read -r tag name package version arch; do
  target="$pool_dir/$name"
  gh release download "$tag" -R "$source_repo" --pattern "$name" \
    --dir "$pool_dir" --clobber >/dev/null \
    || fail "cannot download $name from $tag"
  [[ -f "$target" ]] || fail "$name did not arrive in the pool"

  # The digest comes from the same API as the file and therefore catches
  # transport errors only. The anchor of trust is the attestation below.
  want=$(gh release view "$tag" -R "$source_repo" --json assets |
    "$archive_tool" asset-digest --name "$name") \
    || fail "cannot read the API digest for $name"
  if [[ -n "$want" ]]; then
    have=$(shasum -a 256 "$target" | cut -d' ' -f1)
    [[ "$want" == "$have" ]] || fail "$name does not match the digest the API reports"
  fi

  if ! attestation_output=$(gh attestation verify "$target" --repo "$source_repo" \
      --deny-self-hosted-runners 2>&1); then
    printf '%s\n' "$attestation_output" >&2
    fail "attestation verification failed for $name from $source_repo; \
see the gh diagnostic above"
  fi

  printf '  ok %s  %s %s %s\n' "$name" "$package" "$version" "$arch"
done < "$work/chosen"

printf 'fetched %s packages into %s\n' \
  "$(find "$pool_dir" -name '*.deb' | wc -l | tr -d ' ')" "$pool_dir"
