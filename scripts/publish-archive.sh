#!/usr/bin/env bash
# Laedt einen signierten Archivbaum in den R2-Bucket seiner Domain.
#
#   publish-archive.sh --manifest domains/<host>/manifest.toml \
#                      --project <name> --archive-dir <wurzel> [--preflight]
#
# Zugangsdaten kommen aus der Umgebung, nie aus Argumenten:
#   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY
#
# --preflight prueft Zugang, Bucket und Plan und schreibt nichts. Der Standard
# verlangt das vor jeder oeffentlichen Mutation.
#
# Es wird nie geloescht und nie synchronisiert. Alte by-hash-Dateien muessen
# mindestens eine Release-Generation liegen bleiben, damit ein laufendes
# `apt update` nicht ins Leere greift; ein `sync --delete` wuerde genau die
# entfernen.
set -euo pipefail

fail() { printf '::error::AR150 %s\n' "$*" >&2; exit 1; }

manifest=''; project=''; archive_dir=''; preflight=0
while (($#)); do
  case "$1" in
    --manifest)    manifest=${2:-}; shift 2 ;;
    --project)     project=${2:-}; shift 2 ;;
    --archive-dir) archive_dir=${2:-}; shift 2 ;;
    --preflight)   preflight=1; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done
for name in manifest project archive_dir; do
  [[ -n "${!name}" ]] || fail "--${name//_/-} is required"
done
command -v aws >/dev/null || fail 'the AWS CLI is required for the R2 endpoint'
command -v python3 >/dev/null || fail 'python3 is required'
[[ -f "$manifest"    && ! -L "$manifest"    ]] || fail 'manifest must be a regular file'
[[ -d "$archive_dir" && ! -L "$archive_dir" ]] || fail 'archive-dir must be a real directory'

: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is not set}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is not set}"

script_root=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
planner="$script_root/publication_plan.py"
[[ -f "$planner" && ! -L "$planner" ]] || fail 'the publication planner is missing or unsafe'

# Der Planer laeuft genau einmal. Zweimal aufgerufen koennten die Zahlen
# auseinanderlaufen, falls sich der Baum dazwischen aendert.
plan_json=$(python3 "$planner" --manifest "$manifest" --project "$project" \
              --archive-dir "$archive_dir" --format json) \
  || fail 'cannot compute the publication plan'

plan=$(printf '%s' "$plan_json" | python3 -c '
import json, sys
for e in json.load(sys.stdin)["entries"]:
    print("\t".join((e["phase"], e["local"], e["key"], e["content_type"], str(e["size"]))))
') || fail 'cannot render the publication plan'
[[ -n "$plan" ]] || fail 'the publication plan is empty'

target=$(printf '%s' "$plan_json" | python3 -c '
import json, sys
m = json.load(sys.stdin)["meta"]
print(m["bucket"], m["account_id"], m["base_url"])
') || fail 'cannot read the publication target from the manifest'
read -r bucket account_id base_url <<< "$target"
for name in bucket account_id base_url; do
  [[ -n "${!name}" ]] || fail "the manifest carries no $name"
done

# Der Endpunkt wird aus der Account-ID gebaut, nicht aus dem Manifest gelesen,
# damit dort keine URL stehen kann, die woanders hinzeigt als der Account.
[[ "$account_id" =~ ^[0-9a-f]{32}$ ]] || fail "r2_account_id is malformed: $account_id"
[[ "$bucket" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || fail "r2_bucket is malformed: $bucket"
endpoint="https://${account_id}.r2.cloudflarestorage.com"

# Die Zugangsdaten gehen ueber die Umgebung an die CLI und werden nie
# ausgegeben, auch nicht maskiert.
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
# aws-cli v2 sendet seit 2.23 standardmaessig eine CRC32-Pruefsumme, die
# manche S3-kompatiblen Dienste ablehnen. `when_required` haelt das Verhalten
# beim alten Stand; die inhaltliche Pruefung passiert ohnehin danach gegen die
# oeffentliche URL.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_EC2_METADATA_DISABLED=true
aws_r2=(aws s3api --endpoint-url "$endpoint")

# Ohne Schreibzugriff pruefbar: existiert der Bucket und sind die Daten gueltig.
"${aws_r2[@]}" head-bucket --bucket "$bucket" >/dev/null 2>&1 \
  || fail "cannot reach bucket '$bucket'; check the credentials and the account id"

total=$(printf '%s\n' "$plan" | wc -l | tr -d ' ')
bytes=$(printf '%s\n' "$plan" | awk -F'\t' '{s+=$5} END {print s+0}')
printf 'target %s at %s, %s objects, %s bytes\n' "$bucket" "$base_url" "$total" "$bytes"
for phase in keyring pool indexes release; do
  count=$(printf '%s\n' "$plan" | awk -F'\t' -v p="$phase" '$1==p' | wc -l | tr -d ' ')
  printf '  phase %-8s %s objects\n' "$phase" "$count"
done

if (( preflight )); then
  printf 'preflight only: bucket reachable, plan complete, nothing written\n'
  exit 0
fi

export AR_BUCKET="$bucket" AR_ENDPOINT="$endpoint"

# Zwischen den Phasen ist die Reihenfolge zwingend, innerhalb einer Phase nicht.
# Deshalb parallel je Phase und strikt sequenziell zwischen ihnen.
#
# Die Felder gehen NUL-getrennt an xargs, damit ein Leerzeichen in einem
# Dateinamen nichts zerlegt. `-n 3` liefert dem Helfer Pfad, Schluessel und Typ
# als $1 bis $3.
for phase in keyring pool indexes release; do
  subset=$(printf '%s\n' "$plan" | awk -F'\t' -v p="$phase" '$1==p')
  [[ -n "$subset" ]] || continue
  count=$(printf '%s\n' "$subset" | wc -l | tr -d ' ')

  # `release` bewusst sequenziell: Release, dann Release.gpg, dann InRelease.
  # InRelease liest apt zuerst, es darf nie vor seinen Indexen oben sein.
  parallel=8
  [[ "$phase" == release ]] && parallel=1
  printf 'uploading phase %s, %s objects, parallelism %s\n' "$phase" "$count" "$parallel"

  printf '%s\n' "$subset" |
    awk -F'\t' '{printf "%s%c%s%c%s%c", $2, 0, $3, 0, $4, 0}' |
    xargs -0 -n 3 -P "$parallel" sh -c '
      aws s3api --endpoint-url "$AR_ENDPOINT" put-object \
        --bucket "$AR_BUCKET" --key "$2" --body "$1" --content-type "$3" >/dev/null
    ' _ || fail "phase $phase failed; the archive is now partially published"
done

printf 'published %s objects to %s\n' "$total" "$base_url"
printf 'now verify against the public URL: scripts/verify-publication.sh\n'
