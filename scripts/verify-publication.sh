#!/usr/bin/env bash
# Read-only verification of the complete shared-domain archive and public bytes.
set -euo pipefail
script_root=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
archive_tool=${AR_ARCHIVE_TOOL:-"$script_root/../target/release/apt-archive-tool"}
[[ -x "$archive_tool" && ! -L "$archive_tool" ]] || {
  printf '::error::AR160 the Rust archive tool is missing or unsafe\n' >&2
  exit 1
}
exec "$archive_tool" verify-publication "$@"
