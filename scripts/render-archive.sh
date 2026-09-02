#!/usr/bin/env bash
# Fuehrt den Renderer in einem digest-gepinnten Container ohne Netz aus.
#
# Der Grund fuer den Pin ist Determinismus: die Bytes von Packages.gz haengen an
# der zlib-Version des Hosts. Mit festem Image sind zwei Laeufe auf zwei
# Maschinen byteidentisch, und genau das prueft die Nachkontrolle.
#
# Gemountet werden nur Verzeichnisse, nie einzelne Dateien: manche
# Docker-Backends legen fuer einen Dateimount stillschweigend ein leeres
# Verzeichnis an, und der Lauf scheitert dann mit einer irrefuehrenden Meldung.
#
# AR_RENDER_LOCAL=1 umgeht den Container fuer die Testsuite.
set -euo pipefail

fail() { printf '::error::AR110 %s\n' "$*" >&2; exit 1; }

# Ein `shift 2` ohne Wert bricht mit bashs eigener Meldung ab, und bei
# `set -e` sogar lautlos: Exitcode 1, keine Ausgabe auf stdout oder stderr. In
# einem Workflow bliebe nur "Process completed with exit code 1" stehen.
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
for name in manifest project pool_dir output_dir publication_epoch; do
  [[ -n "${!name}" ]] || fail "--${name//_/-} is required"
done
[[ -f "$manifest" && ! -L "$manifest" ]] || fail 'manifest must be a regular file'
[[ -d "$pool_dir"  && ! -L "$pool_dir"  ]] || fail 'pool-dir must be a real directory'
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || fail 'output-dir must be a new path'
[[ "$publication_epoch" =~ ^[1-9][0-9]*$ ]] || fail 'publication-epoch must be a positive integer'

manifest_dir=$(unset CDPATH; cd -- "$(dirname -- "$manifest")" && pwd -P)
manifest_name=$(basename -- "$manifest")

args=(--manifest "/manifest/$manifest_name" --project "$project" --pool-dir /pool
      --output-dir /out/archive --publication-epoch "$publication_epoch")
[[ -n "$component" ]] && args+=(--component "$component")

if [[ "${AR_RENDER_LOCAL:-}" == 1 ]]; then
  exec python3 "$renderer" --manifest "$manifest" --project "$project" \
    --pool-dir "$pool_dir" --output-dir "$output_dir" \
    --publication-epoch "$publication_epoch" ${component:+--component "$component"}
fi

command -v docker >/dev/null || fail 'Docker is required for the pinned renderer'

# Der Elternpfad kann fehlen, und output_dir kann relativ sein. Erst anlegen,
# dann absolut aufloesen: ohne das scheitert `cd` am fehlenden Verzeichnis, und
# das abschliessende `mv` landet relativ zum aufrufenden Arbeitsverzeichnis.
parent_raw=$(dirname -- "$output_dir")
mkdir -p -- "$parent_raw" || fail "cannot create the parent of output-dir: $parent_raw"
parent=$(unset CDPATH; cd -- "$parent_raw" && pwd -P) \
  || fail "cannot resolve the parent of output-dir: $parent_raw"
output_dir="$parent/$(basename -- "$output_dir")"
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || fail 'output-dir must be a new path'

staging=$(mktemp -d "$parent/.render.XXXXXX") \
  || fail "cannot create renderer staging directory below $parent"
trap 'rm -rf -- "$staging"' EXIT

docker run --rm --network none --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --memory 512m --memory-swap 512m --pids-limit 64 --cpus 2 \
  --user "$(id -u):$(id -g)" \
  --volume "$script_root:/scripts:ro" \
  --volume "$manifest_dir:/manifest:ro" \
  --volume "$(cd "$pool_dir" && pwd -P):/pool:ro" \
  --volume "$staging:/out:rw" \
  python:3.14.2-slim-bookworm@sha256:e87711ef5c86aaeaa7031718a69db79d334d94c545c709583f651b8185870941 \
  python3 /scripts/render_archive.py "${args[@]}"

mv "$staging/archive" "$output_dir"
