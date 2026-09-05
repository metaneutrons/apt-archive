#!/usr/bin/env bash
# Pure contract tests for the two-stage GitHub release selection.
set -uo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)
selector="$root/scripts/select_assets.py"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; fi; }
reject() {
  name=$1; fragment=$2; json=$3
  output=$(printf '%s' "$json" | python3 "$selector" --stage tags --keep 5 2>&1)
  status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$output" | grep -qF "$fragment"; then
    ok "$name"
  else
    bad "$name"
  fi
}
reject_assets() {
  name=$1; fragment=$2; json=$3
  output=$(printf '%s' "$json" | python3 "$selector" --stage assets \
    --packages demo,demo-doc --architectures amd64,arm64 2>&1)
  status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$output" | grep -qF "$fragment"; then
    ok "$name"
  else
    bad "$name"
  fi
}

printf '\n== Order ==\n'
listing='[
  {"tagName":"v2-z","isDraft":false,"isPrerelease":false,"publishedAt":"2026-09-02T10:00:00Z"},
  {"tagName":"v1","isDraft":false,"isPrerelease":false,"publishedAt":"2026-09-01T10:00:00Z"},
  {"tagName":"v2-a","isDraft":false,"isPrerelease":false,"publishedAt":"2026-09-02T10:00:00Z"},
  {"tagName":"v3-rc","isDraft":false,"isPrerelease":true,"publishedAt":"2026-09-03T10:00:00Z"}
]'
chosen=$(printf '%s' "$listing" | python3 "$selector" --stage tags --keep 3 2>/dev/null | tr '\n' ' ')
check "equal times are resolved by tag, ascending" "$chosen" "v2-a v2-z v1 "
reject "drafts and prereleases alone yield no stable release" "no stable release" \
  '[{"tagName":"v1","isDraft":true,"isPrerelease":false,"publishedAt":null}]'
reject "a tag with a slash is rejected before gh" "unsafe tag name" \
  '[{"tagName":"bad/tag","isDraft":false,"isPrerelease":false,"publishedAt":"2026-09-01T00:00:00Z"}]'
reject "a release that is not an object is rejected" "release 0 is not an object" \
  '[null]'

invalid=$(printf '{' | python3 "$selector" --stage tags --keep 1 2>&1)
if [ $? -ne 0 ] && printf '%s' "$invalid" | grep -qF 'cannot parse the release listing'; then
  ok "invalid JSON is rejected by name"
else
  bad "invalid JSON is rejected by name"
fi
non_array=$(printf '{}' | python3 "$selector" --stage tags --keep 1 2>&1)
if [ $? -ne 0 ] && printf '%s' "$non_array" | grep -qF 'must be a JSON array'; then
  ok "a JSON object instead of a list is rejected"
else
  bad "a JSON object instead of a list is rejected"
fi
bad_keep=$(printf '[]' | python3 "$selector" --stage tags --keep 0 2>&1)
if [ $? -ne 0 ] && printf '%s' "$bad_keep" | grep -qF 'keep must be at least 1'; then
  ok "a keep below one is rejected"
else
  bad "a keep below one is rejected"
fi

printf '\n== Missing API fields ==\n'
reject "a missing isDraft is rejected" "boolean isDraft" \
  '[{"tagName":"v1","isPrerelease":false,"publishedAt":"2026-09-01T00:00:00Z"}]'
reject "a missing isPrerelease is rejected" "boolean isPrerelease" \
  '[{"tagName":"v1","isDraft":false,"publishedAt":"2026-09-01T00:00:00Z"}]'
reject "a non-boolean draft field is rejected" "boolean isDraft" \
  '[{"tagName":"v1","isDraft":0,"isPrerelease":false,"publishedAt":"2026-09-01T00:00:00Z"}]'
reject "a missing tagName is rejected" "no tag name" \
  '[{"isDraft":false,"isPrerelease":false,"publishedAt":"2026-09-01T00:00:00Z"}]'
reject "a missing publishedAt is rejected even for a draft" "no publishedAt field" \
  '[{"tagName":"v1","isDraft":true,"isPrerelease":false}]'
reject "an empty publishedAt on a stable version is rejected" "no publication date" \
  '[{"tagName":"v1","isDraft":false,"isPrerelease":false,"publishedAt":""}]'

printf '\n== Asset response ==\n'
reject_assets "a missing assets field is rejected" "no assets array" \
  '[{"tagName":"v1"}]'
reject_assets "an asset release that is not an object is rejected" \
  "asset listing must hold objects" '[null]'
reject_assets "an asset release without a tag is rejected" "release carries no tag name" \
  '[{"assets":[]}]'
reject_assets "an asset that is not an object is rejected" "asset carries no name" \
  '[{"tagName":"v1","assets":[null]}]'
reject_assets "a non-canonical Debian file name is rejected" \
  "not a canonical Debian binary name" \
  '[{"tagName":"v1","assets":[{"name":"demo_bad?.deb"}]}]'
reject_assets "no declared package is rejected" \
  "no stable release carries a .deb" \
  '[{"tagName":"v1","assets":[{"name":"other_1.0.0_amd64.deb"}]}]'
reject_assets "an unserved architecture is not selected" \
  "no stable release carries a .deb" \
  '[{"tagName":"v1","assets":[{"name":"demo_1.0.0_riscv64.deb"}]}]'
reject_assets "a duplicate package identity across releases is rejected" \
  "one identity cannot come from two releases" \
  '[{"tagName":"v2","assets":[{"name":"demo_1.0.0_amd64.deb"}]},{"tagName":"v1","assets":[{"name":"demo_1.0.0_amd64.deb"}]}]'
reject_assets "every declared package is required at least once" \
  "required package(s): demo-doc" \
  '[{"tagName":"v1","assets":[{"name":"demo_1.0.0_amd64.deb"}]}]'

missing_args=$(printf '[]' | python3 "$selector" --stage assets 2>&1)
if [ $? -ne 0 ] && printf '%s' "$missing_args" | grep -qF 'are required for --stage assets'; then
  ok "missing asset arguments are rejected"
else
  bad "missing asset arguments are rejected"
fi
empty_args=$(printf '[]' | python3 "$selector" --stage assets \
  --packages , --architectures , 2>&1)
if [ $? -ne 0 ] && printf '%s' "$empty_args" | grep -qF 'must not be empty'; then
  ok "empty package and architecture sets are rejected"
else
  bad "empty package and architecture sets are rejected"
fi

assets='[{"tagName":"v1","assets":[
  {"name":"notes.txt"},
  {"name":"other_1.0.0_amd64.deb"},
  {"name":"demo_1.0.0_amd64.deb"},
  {"name":"demo-doc_1.0.0_all.deb"}
]}]'
selected=$(printf '%s' "$assets" | python3 "$selector" --stage assets \
  --packages demo,demo-doc --architectures amd64,arm64 2>/dev/null)
check "only declared, matching assets are emitted" \
  "$(printf '%s\n' "$selected" | wc -l | tr -d ' ')" "2"
check "Architecture all is kept as a portable asset" \
  "$(printf '%s\n' "$selected" | awk -F'\t' '$5 == "all" {print $2}')" \
  "demo-doc_1.0.0_all.deb"

printf '\n  passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
