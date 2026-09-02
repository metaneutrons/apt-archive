#!/usr/bin/env bash
# Reine Vertragstests fuer die zweistufige GitHub-Release-Auswahl.
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

printf '\n== Reihenfolge ==\n'
listing='[
  {"tagName":"v2-z","isDraft":false,"isPrerelease":false,"publishedAt":"2026-09-02T10:00:00Z"},
  {"tagName":"v1","isDraft":false,"isPrerelease":false,"publishedAt":"2026-09-01T10:00:00Z"},
  {"tagName":"v2-a","isDraft":false,"isPrerelease":false,"publishedAt":"2026-09-02T10:00:00Z"},
  {"tagName":"v3-rc","isDraft":false,"isPrerelease":true,"publishedAt":"2026-09-03T10:00:00Z"}
]'
chosen=$(printf '%s' "$listing" | python3 "$selector" --stage tags --keep 3 2>/dev/null | tr '\n' ' ')
check "gleiche Zeit wird aufsteigend nach Tag aufgeloest" "$chosen" "v2-a v2-z v1 "
reject "nur Drafts und Prereleases ergeben keinen stabilen Release" "no stable release" \
  '[{"tagName":"v1","isDraft":true,"isPrerelease":false,"publishedAt":null}]'
reject "Tag mit Slash wird vor gh abgelehnt" "unsafe tag name" \
  '[{"tagName":"bad/tag","isDraft":false,"isPrerelease":false,"publishedAt":"2026-09-01T00:00:00Z"}]'
reject "nicht-objektfoermiger Release wird abgelehnt" "release 0 is not an object" \
  '[null]'

invalid=$(printf '{' | python3 "$selector" --stage tags --keep 1 2>&1)
if [ $? -ne 0 ] && printf '%s' "$invalid" | grep -qF 'cannot parse the release listing'; then
  ok "ungueltiges JSON wird benannt abgelehnt"
else
  bad "ungueltiges JSON wird benannt abgelehnt"
fi
non_array=$(printf '{}' | python3 "$selector" --stage tags --keep 1 2>&1)
if [ $? -ne 0 ] && printf '%s' "$non_array" | grep -qF 'must be a JSON array'; then
  ok "JSON-Objekt statt Liste wird abgelehnt"
else
  bad "JSON-Objekt statt Liste wird abgelehnt"
fi
bad_keep=$(printf '[]' | python3 "$selector" --stage tags --keep 0 2>&1)
if [ $? -ne 0 ] && printf '%s' "$bad_keep" | grep -qF 'keep must be at least 1'; then
  ok "keep kleiner eins wird abgelehnt"
else
  bad "keep kleiner eins wird abgelehnt"
fi

printf '\n== Fehlende API-Felder ==\n'
reject "fehlendes isDraft wird abgelehnt" "boolean isDraft" \
  '[{"tagName":"v1","isPrerelease":false,"publishedAt":"2026-09-01T00:00:00Z"}]'
reject "fehlendes isPrerelease wird abgelehnt" "boolean isPrerelease" \
  '[{"tagName":"v1","isDraft":false,"publishedAt":"2026-09-01T00:00:00Z"}]'
reject "nicht-boolesches Draft-Feld wird abgelehnt" "boolean isDraft" \
  '[{"tagName":"v1","isDraft":0,"isPrerelease":false,"publishedAt":"2026-09-01T00:00:00Z"}]'
reject "fehlendes tagName wird abgelehnt" "no tag name" \
  '[{"isDraft":false,"isPrerelease":false,"publishedAt":"2026-09-01T00:00:00Z"}]'
reject "fehlendes publishedAt wird auch bei Draft abgelehnt" "no publishedAt field" \
  '[{"tagName":"v1","isDraft":true,"isPrerelease":false}]'
reject "leeres publishedAt einer stabilen Version wird abgelehnt" "no publication date" \
  '[{"tagName":"v1","isDraft":false,"isPrerelease":false,"publishedAt":""}]'

printf '\n== Asset-Antwort ==\n'
reject_assets "fehlendes assets-Feld wird abgelehnt" "no assets array" \
  '[{"tagName":"v1"}]'
reject_assets "nicht-objektfoermiger Asset-Release wird abgelehnt" \
  "asset listing must hold objects" '[null]'
reject_assets "Asset-Release ohne Tag wird abgelehnt" "release carries no tag name" \
  '[{"assets":[]}]'
reject_assets "nicht-objektfoermiges Asset wird abgelehnt" "asset carries no name" \
  '[{"tagName":"v1","assets":[null]}]'
reject_assets "nicht-kanonischer Debian-Dateiname wird abgelehnt" \
  "not a canonical Debian binary name" \
  '[{"tagName":"v1","assets":[{"name":"demo_bad?.deb"}]}]'
reject_assets "kein deklariertes Paket wird abgelehnt" \
  "no stable release carries a .deb" \
  '[{"tagName":"v1","assets":[{"name":"other_1.0.0_amd64.deb"}]}]'
reject_assets "nicht bediente Architektur wird nicht ausgewaehlt" \
  "no stable release carries a .deb" \
  '[{"tagName":"v1","assets":[{"name":"demo_1.0.0_riscv64.deb"}]}]'
reject_assets "doppelte Paketidentitaet ueber Releases wird abgelehnt" \
  "one identity cannot come from two releases" \
  '[{"tagName":"v2","assets":[{"name":"demo_1.0.0_amd64.deb"}]},{"tagName":"v1","assets":[{"name":"demo_1.0.0_amd64.deb"}]}]'
reject_assets "jedes deklarierte Paket ist mindestens einmal erforderlich" \
  "required package(s): demo-doc" \
  '[{"tagName":"v1","assets":[{"name":"demo_1.0.0_amd64.deb"}]}]'

missing_args=$(printf '[]' | python3 "$selector" --stage assets 2>&1)
if [ $? -ne 0 ] && printf '%s' "$missing_args" | grep -qF 'are required for --stage assets'; then
  ok "fehlende Asset-Argumente werden abgelehnt"
else
  bad "fehlende Asset-Argumente werden abgelehnt"
fi
empty_args=$(printf '[]' | python3 "$selector" --stage assets \
  --packages , --architectures , 2>&1)
if [ $? -ne 0 ] && printf '%s' "$empty_args" | grep -qF 'must not be empty'; then
  ok "leere Paket- und Architekturmengen werden abgelehnt"
else
  bad "leere Paket- und Architekturmengen werden abgelehnt"
fi

assets='[{"tagName":"v1","assets":[
  {"name":"notes.txt"},
  {"name":"other_1.0.0_amd64.deb"},
  {"name":"demo_1.0.0_amd64.deb"},
  {"name":"demo-doc_1.0.0_all.deb"}
]}]'
selected=$(printf '%s' "$assets" | python3 "$selector" --stage assets \
  --packages demo,demo-doc --architectures amd64,arm64 2>/dev/null)
check "nur deklarierte passende Assets werden ausgegeben" \
  "$(printf '%s\n' "$selected" | wc -l | tr -d ' ')" "2"
check "Architecture all bleibt als portables Asset erhalten" \
  "$(printf '%s\n' "$selected" | awk -F'\t' '$5 == "all" {print $2}')" \
  "demo-doc_1.0.0_all.deb"

printf '\n  bestanden %d, fehlgeschlagen %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
