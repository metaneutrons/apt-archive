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
for command in gh python3 shasum; do
  command -v "$command" >/dev/null || fail "required command is missing: $command"
done
[[ -f "$manifest" && ! -L "$manifest" ]] || fail 'manifest must be a regular file'
[[ ! -e "$pool_dir" && ! -L "$pool_dir" ]] || fail 'pool-dir must be a new path'

script_root=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
selector="$script_root/select_assets.py"
[[ -f "$selector" && ! -L "$selector" ]] || fail 'the asset selector is missing or unsafe'

read -r source_repo packages architectures keep < <(
  MANIFEST="$manifest" PROJECT="$project" python3 - <<'PY'
import os, tomllib
with open(os.environ["MANIFEST"], "rb") as handle:
    data = tomllib.load(handle)
project = os.environ["PROJECT"]
matches = [p for p in data.get("projects", []) if isinstance(p, dict) and p.get("name") == project]
if len(matches) != 1:
    raise SystemExit(f"project {project!r} is not declared exactly once")
entry = matches[0]
for key in ("source_repo", "packages", "keep_versions"):
    if key not in entry:
        raise SystemExit(f"project {project!r} declares no {key}")
keep = entry["keep_versions"]
# bool is a subclass of int and must not pass as a number here.
if not isinstance(keep, int) or isinstance(keep, bool) or keep < 1:
    raise SystemExit(f"keep_versions must be a positive integer, not {keep!r}")
repo = entry["source_repo"]
if not isinstance(repo, str) or repo.count("/") != 1:
    raise SystemExit(f"source_repo must be owner/name, not {repo!r}")
print(repo, ",".join(entry["packages"]),
      ",".join(data["release"]["architectures"]), keep)
PY
) || fail 'cannot read the project from the manifest'

printf 'fetching from %s, keeping %s stable releases\n' "$source_repo" "$keep"

work=$(mktemp -d /tmp/apt-archive-fetch.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

gh release list -R "$source_repo" --limit 200 \
  --json tagName,isDraft,isPrerelease,publishedAt > "$work/releases.json" \
  || fail "cannot list the releases of $source_repo"
python3 "$selector" --stage tags --keep "$keep" < "$work/releases.json" > "$work/tags" \
  || fail 'no usable release'
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
  done < "$work/tags"
  printf ']'
} > "$work/assets.json"

python3 "$selector" --stage assets --packages "$packages" \
  --architectures "$architectures" < "$work/assets.json" > "$work/chosen" \
  || fail 'no asset matches the declared packages'
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
  want=$(TAG="$tag" NAME="$name" REPO="$source_repo" python3 - <<'PY'
import json, os, subprocess
raw = subprocess.run(
    ["gh", "release", "view", os.environ["TAG"], "-R", os.environ["REPO"],
     "--json", "assets"],
    capture_output=True, text=True, check=True).stdout
payload = json.loads(raw)
assets = payload.get("assets")
if not isinstance(assets, list):
    raise SystemExit("release response carries no assets array")
matches = [asset for asset in assets
           if isinstance(asset, dict) and asset.get("name") == os.environ["NAME"]]
if len(matches) != 1:
    raise SystemExit(f"release response names the selected asset {len(matches)} times")
asset = matches[0]
if "digest" not in asset:
    raise SystemExit("selected asset carries no digest field")
digest = asset["digest"]
if digest is None or digest == "":
    print("")
elif isinstance(digest, str) and digest.startswith("sha256:"):
    print(digest.removeprefix("sha256:"))
else:
    raise SystemExit(f"selected asset carries an unsupported digest: {digest!r}")
PY
) || fail "cannot read the API digest for $name"
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
