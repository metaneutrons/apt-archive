#!/usr/bin/env bash
# Render one deterministic shared-domain APT archive with the pinned Rust tool.
set -euo pipefail

fail() { printf '::error::AR110 %s\n' "$*" >&2; exit 1; }
opt_value() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"; }

manifest=''; project=''; pool_dir=''; output_dir=''
publication_epoch=''; component=''
while (($#)); do
  case "$1" in
    --manifest) opt_value "$@"; manifest=$2; shift 2 ;;
    --project) opt_value "$@"; project=$2; shift 2 ;;
    --pool-dir) opt_value "$@"; pool_dir=$2; shift 2 ;;
    --output-dir) opt_value "$@"; output_dir=$2; shift 2 ;;
    --publication-epoch) opt_value "$@"; publication_epoch=$2; shift 2 ;;
    --component) opt_value "$@"; component=$2; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
for name in manifest pool_dir output_dir publication_epoch; do
  [[ -n "${!name}" ]] || fail "--${name//_/-} is required"
done
[[ -f "$manifest" && ! -L "$manifest" ]] || fail 'manifest must be a regular file'
[[ -d "$pool_dir" && ! -L "$pool_dir" ]] || fail 'pool-dir must be a real directory'
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || fail 'output-dir must be a new path'
[[ "$publication_epoch" =~ ^[1-9][0-9]*$ ]] || fail 'publication-epoch must be positive'

script_root=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
archive_tool=${AR_ARCHIVE_TOOL:-"$script_root/../target/release/apt-archive-tool"}
[[ -x "$archive_tool" && ! -L "$archive_tool" ]] \
  || fail 'the Rust archive tool is missing or unsafe; build it with cargo build --release --locked'

args=(render --manifest "$manifest" --pool-dir "$pool_dir" --output-dir "$output_dir"
      --publication-epoch "$publication_epoch")
[[ -n "$project" ]] && args+=(--project "$project")
[[ -n "$component" ]] && args+=(--component "$component")
exec "$archive_tool" "${args[@]}"
