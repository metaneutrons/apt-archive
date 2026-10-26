#!/usr/bin/env bash
# Runs the renderer in a digest-pinned container without a network.
#
# The reason for the pin is determinism: the bytes of Packages.gz depend on the
# host's zlib version. With a fixed image two runs on two machines are
# byte-identical, and that is exactly what the after-check verifies.
#
# Only directories are mounted, never single files: some Docker backends
# silently create an empty directory for a file mount, and the run then fails
# with a misleading message.
#
# AR_RENDER_LOCAL=1 bypasses the container for the test suite.
set -euo pipefail

fail() { printf '::error::AR110 %s\n' "$*" >&2; exit 1; }

# A `shift 2` without a value aborts with bash's own message, and under
# `set -e` even silently: exit code 1, nothing on stdout or stderr. In a
# workflow all that would remain is "Process completed with exit code 1".
opt_value() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"; }

script_root=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
renderer="$script_root/render_archive.py"
[[ -f "$renderer" && ! -L "$renderer" ]] || fail 'renderer is missing or unsafe'

manifest=''; project=''; pool_dir=''; output_dir=''
publication_epoch=''; component=''
while (($#)); do
  case "$1" in
    --manifest)       opt_value "$@"; manifest=$2; shift 2 ;;
    --project)        opt_value "$@"; project=$2; shift 2 ;;
    --pool-dir)       opt_value "$@"; pool_dir=$2; shift 2 ;;
    --output-dir)     opt_value "$@"; output_dir=$2; shift 2 ;;
    --publication-epoch) opt_value "$@"; publication_epoch=$2; shift 2 ;;
    --component)      opt_value "$@"; component=$2; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
for name in manifest pool_dir output_dir publication_epoch; do
  [[ -n "${!name}" ]] || fail "--${name//_/-} is required"
done
[[ -f "$manifest" && ! -L "$manifest" ]] || fail 'manifest must be a regular file'
[[ -d "$pool_dir"  && ! -L "$pool_dir"  ]] || fail 'pool-dir must be a real directory'
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || fail 'output-dir must be a new path'
[[ "$publication_epoch" =~ ^[1-9][0-9]*$ ]] || fail 'publication-epoch must be a positive integer'

manifest_dir=$(unset CDPATH; cd -- "$(dirname -- "$manifest")" && pwd -P)
manifest_name=$(basename -- "$manifest")

args=(--manifest "/manifest/$manifest_name" --pool-dir /pool
      --output-dir /out/archive --publication-epoch "$publication_epoch")
[[ -n "$project" ]] && args+=(--project "$project")
[[ -n "$component" ]] && args+=(--component "$component")

if [[ "${AR_RENDER_LOCAL:-}" == 1 ]]; then
  exec python3 "$renderer" --manifest "$manifest" ${project:+--project "$project"} \
    --pool-dir "$pool_dir" --output-dir "$output_dir" \
    --publication-epoch "$publication_epoch" ${component:+--component "$component"}
fi

command -v docker >/dev/null || fail 'Docker is required for the pinned renderer'

# The parent path can be missing, and output_dir can be relative. Create it
# first, then resolve it absolutely: without that `cd` fails on the missing
# directory, and the closing `mv` lands relative to the calling directory.
parent_raw=$(dirname -- "$output_dir")
mkdir -p -- "$parent_raw" || fail "cannot create the parent of output-dir: $parent_raw"
parent=$(unset CDPATH; cd -- "$parent_raw" && pwd -P) \
  || fail "cannot resolve the parent of output-dir: $parent_raw"
output_dir="$parent/$(basename -- "$output_dir")"
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || fail 'output-dir must be a new path'

staging=$(mktemp -d "$parent/.render.XXXXXX") \
  || fail "cannot create renderer staging directory below $parent"
renderer_state_dir=''
renderer_cid_file=''
renderer_container_id=''
renderer_run_started=0

cleanup_renderer() {
  local status=$?
  local cleanup_failed=0
  trap - EXIT
  trap ':' INT TERM

  if [[ -z "$renderer_container_id" && -n "$renderer_cid_file" \
        && -f "$renderer_cid_file" \
        && ! -L "$renderer_cid_file" ]]; then
    if renderer_container_id=$(cat -- "$renderer_cid_file"); then
      :
    else
      renderer_container_id=''
    fi
  fi
  if (( status != 0 && renderer_run_started != 0 )); then
    if [[ "$renderer_container_id" =~ ^[[:xdigit:]]{64}$ ]]; then
      if renderer_diagnostics=$(docker inspect --format \
          'renderer diagnostics: OOMKilled={{.State.OOMKilled}} Running={{.State.Running}} ExitCode={{.State.ExitCode}} MemoryBytes={{.HostConfig.Memory}} MemorySwapBytes={{.HostConfig.MemorySwap}}' \
          "$renderer_container_id" 2>/dev/null); then
        printf '%s\n' "$renderer_diagnostics" >&2
      else
        printf '::warning::AR114 renderer container diagnostics unavailable\n' >&2
      fi
    else
      printf '::warning::AR114 renderer container diagnostics unavailable\n' >&2
    fi
  fi
  if [[ "$renderer_container_id" =~ ^[[:xdigit:]]{64}$ ]]; then
    if docker rm --force "$renderer_container_id" >/dev/null 2>&1; then
      renderer_container_id=''
    else
      printf '::error::AR111 failed to remove renderer container\n' >&2
      cleanup_failed=1
    fi
  elif [[ -n "$renderer_container_id" ]]; then
    printf '::error::AR111 renderer container ID was invalid; it was not removed\n' >&2
    cleanup_failed=1
  fi
  if [[ -n "$renderer_state_dir" ]]; then
    if rm -rf -- "$renderer_state_dir"; then
      :
    else
      printf '::error::AR112 failed to remove renderer state directory\n' >&2
      cleanup_failed=1
    fi
  fi
  if rm -rf -- "$staging"; then
    :
  else
    printf '::error::AR113 failed to remove renderer staging directory\n' >&2
    cleanup_failed=1
  fi
  if (( status == 0 && cleanup_failed != 0 )); then status=1; fi
  exit "$status"
}
trap cleanup_renderer EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

renderer_state_dir=$(mktemp -d "${TMPDIR:-/tmp}/apt-renderer.XXXXXX") \
  || fail 'cannot create renderer state directory'
renderer_cid_file="$renderer_state_dir/container-id"

renderer_run_started=1
if docker run --cidfile "$renderer_cid_file" --network none --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    --memory 2g --memory-swap 2g --pids-limit 64 --cpus 2 \
    --user "$(id -u):$(id -g)" \
    --volume "$script_root:/scripts:ro" \
    --volume "$manifest_dir:/manifest:ro" \
    --volume "$(cd "$pool_dir" && pwd -P):/pool:ro" \
    --volume "$staging:/out:rw" \
    python:3.14.2-slim-bookworm@sha256:e87711ef5c86aaeaa7031718a69db79d334d94c545c709583f651b8185870941 \
    python3 /scripts/render_archive.py "${args[@]}"; then
  :
else
  renderer_status=$?
  exit "$renderer_status"
fi

if [[ -f "$renderer_cid_file" && ! -L "$renderer_cid_file" ]]; then
  if renderer_container_id=$(cat -- "$renderer_cid_file"); then
    :
  else
    renderer_container_id=''
  fi
fi
if [[ ! "$renderer_container_id" =~ ^[[:xdigit:]]{64}$ ]]; then
  printf '::error::AR115 Docker succeeded without a valid renderer container ID\n' >&2
  exit 1
fi

mv "$staging/archive" "$output_dir"
