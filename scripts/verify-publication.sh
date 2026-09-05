#!/usr/bin/env bash
# Read-only verification of the complete shared-domain archive and public bytes.
set -euo pipefail
script_root=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 "$script_root/verify_publication.py" "$@"
