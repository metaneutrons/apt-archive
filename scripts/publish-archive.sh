#!/usr/bin/env bash
# Uploads a signed archive tree into its domain's R2 bucket.
#
#   publish-archive.sh --manifest domains/<host>/manifest.toml \
#                      --project <name> --archive-dir <root> \
#                      --publication-epoch <epoch> [--preflight]
#
# Credentials come from the environment, never from arguments:
#   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY
#
# --preflight checks access, the bucket and the plan and writes nothing. The
# standard demands that before every public mutation.
#
# Nothing is ever deleted and nothing is ever synchronised. Old by-hash files
# have to stay for at least one release generation, so that an `apt update` in
# flight does not grasp at nothing; a `sync --delete` would remove exactly
# those.
set -euo pipefail

fail() { printf '::error::AR150 %s\n' "$*" >&2; exit 1; }

# A `shift 2` without a value aborts with bash's own message, and under
# `set -e` even silently: exit code 1, nothing on stdout or stderr. In a
# workflow all that would remain is "Process completed with exit code 1".
opt_value() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"; }

manifest=''; project=''; archive_dir=''; publication_epoch=''; baseline=''; preflight=0
while (($#)); do
  case "$1" in
    --manifest)    opt_value "$@"; manifest=$2; shift 2 ;;
    --project)     opt_value "$@"; project=$2; shift 2 ;;
    --archive-dir) opt_value "$@"; archive_dir=$2; shift 2 ;;
    --publication-epoch) opt_value "$@"; publication_epoch=$2; shift 2 ;;
    --baseline) opt_value "$@"; baseline=$2; shift 2 ;;
    --preflight)   preflight=1; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done
for name in manifest archive_dir publication_epoch; do
  [[ -n "${!name}" ]] || fail "--${name//_/-} is required"
done
command -v aws >/dev/null || fail 'the AWS CLI is required for the R2 endpoint'
command -v python3 >/dev/null || fail 'python3 is required'
[[ -f "$manifest"    && ! -L "$manifest"    ]] || fail 'manifest must be a regular file'
[[ -d "$archive_dir" && ! -L "$archive_dir" ]] || fail 'archive-dir must be a real directory'
[[ "$publication_epoch" =~ ^[1-9][0-9]*$ ]] \
  || fail 'publication-epoch must be a positive integer'

: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is not set}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is not set}"

script_root=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
planner="$script_root/publication_plan.py"
[[ -f "$planner" && ! -L "$planner" ]] || fail 'the publication planner is missing or unsafe'

# The planner runs exactly once. Called twice, the numbers could drift apart
# if the tree changes in between.
plan_json=$(python3 "$planner" --manifest "$manifest" ${project:+--project "$project"} \
              --archive-dir "$archive_dir" --publication-epoch "$publication_epoch" \
              --format json) \
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

# The endpoint is built from the account ID rather than read from the manifest,
# so that no URL there can point somewhere other than the account.
[[ "$account_id" =~ ^[0-9a-f]{32}$ ]] || fail "r2_account_id is malformed: $account_id"
[[ "$bucket" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || fail "r2_bucket is malformed: $bucket"
endpoint="https://${account_id}.r2.cloudflarestorage.com"

# The credentials reach the CLI through the environment and are never printed,
# not even masked.
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
# Since 2.23 aws-cli v2 sends a CRC32 checksum by default, which some
# S3-compatible services reject. `when_required` keeps the behaviour as it was;
# the substantive check happens afterwards anyway, against the public URL.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_EC2_METADATA_DISABLED=true
aws_r2=(aws s3api --endpoint-url "$endpoint")

# Checkable without write access: does the bucket exist and are the data valid.
"${aws_r2[@]}" head-bucket --bucket "$bucket" >/dev/null 2>&1 \
  || fail "cannot reach bucket '$bucket'; check the credentials and the account id"

# The full signed domain must have been restored before this candidate was
# rendered. Compare its generation and every immutable object before any PUT.
[[ -n "$baseline" && -f "$baseline" && ! -L "$baseline" ]] \
  || fail 'a regular --baseline from domain_snapshot.py prepare is required'
transaction=$(mktemp -d /tmp/apt-domain-publish.XXXXXX)
trap 'rm -rf -- "$transaction"' EXIT
printf '%s' "$plan_json" > "$transaction/plan.json"
python3 "$script_root/verify_publication.py" --manifest "$manifest" \
  --archive-dir "$archive_dir" --publication-epoch "$publication_epoch" --local-only \
  || fail 'signed candidate integrity failed; nothing written'
plan=$(python3 "$script_root/domain_snapshot.py" guard --manifest "$manifest" \
  --baseline "$baseline" --plan "$transaction/plan.json") \
  || fail 'domain generation or immutable-object preflight failed; nothing written'

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

# Between the phases the order is mandatory, within a phase it is not.
# Hence parallel within a phase and strictly sequential between them.
#
# The fields reach xargs NUL-separated, so that a space in a file name breaks
# nothing. `-n 3` hands the helper the path, the key and the type as $1 to
# $3.
for phase in keyring pool indexes release; do
  subset=$(printf '%s\n' "$plan" | awk -F'\t' -v p="$phase" '$1==p')
  [[ -n "$subset" ]] || continue
  count=$(printf '%s\n' "$subset" | wc -l | tr -d ' ')

  # `release` deliberately without xargs and strictly sequential: Release, then
  # Release.gpg, then InRelease. After exit code 1 xargs carries on with the
  # next record; with these three metadata files that must not happen.
  if [[ "$phase" == release ]]; then
    previous_etag=$(python3 "$script_root/domain_snapshot.py" commit-guard \
      --manifest "$manifest" --baseline "$baseline") \
      || fail 'generation changed before commit; later metadata was not uploaded'
    printf 'uploading phase %s, %s objects, strictly sequential\n' "$phase" "$count"
    while IFS=$'\t' read -r _phase_name local_path object_key content_type _object_size; do
      condition=()
      if [[ "$object_key" == */InRelease ]]; then
        if [[ "$previous_etag" == ABSENT ]]; then
          condition=(--if-none-match '*')
        else
          condition=(--if-match "$previous_etag")
        fi
      fi
      aws s3api --endpoint-url "$AR_ENDPOINT" put-object \
        --bucket "$AR_BUCKET" --key "$object_key" --body "$local_path" \
        --content-type "$content_type" "${condition[@]}" >/dev/null \
        || fail "release upload failed at $object_key; later metadata was not uploaded"
    done <<< "$subset"
    continue
  fi

  parallel=8
  printf 'uploading phase %s, %s objects, parallelism %s\n' "$phase" "$count" "$parallel"

  printf '%s\n' "$subset" |
    awk -F'\t' '{printf "%s%c%s%c%s%c", $2, 0, $3, 0, $4, 0}' |
    xargs -0 -n 3 -P "$parallel" sh -c '
      # A second writer must not overwrite an immutable object after the
      # preflight. Domain concurrency prevents the ordinary race; the
      # conditional PUT makes a violated assumption fail closed too.
      case "$2" in pool/*|*/by-hash/*) set -- "$@" --if-none-match "*" ;; esac
      aws s3api --endpoint-url "$AR_ENDPOINT" put-object \
        --bucket "$AR_BUCKET" --key "$2" --body "$1" --content-type "$3" \
        ${4:+"$4"} ${5:+"$5"} >/dev/null
    ' _ || fail "phase $phase failed; the archive is now partially published"
done

printf 'published %s objects to %s\n' "$total" "$base_url"
printf 'now verify against the public URL: scripts/verify-publication.sh\n'
