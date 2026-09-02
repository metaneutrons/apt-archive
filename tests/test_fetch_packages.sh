#!/usr/bin/env bash
# Belegt, dass die echte gh-Diagnose beim Attestierungsfehler sichtbar bleibt.
set -uo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d /tmp/apt-archive-fetch-test.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"

cat > "$work/manifest.toml" <<'TOML'
[release]
architectures = ["amd64"]

[[projects]]
name = "demo"
source_repo = "owner/repo"
packages = ["demo"]
keep_versions = 1
TOML

cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'release list')
    printf '%s\n' '[{"tagName":"v1","isDraft":false,"isPrerelease":false,"publishedAt":"2026-09-01T00:00:00Z"}]'
    ;;
  'release view')
    if [ "${FAKE_MISSING_DIGEST:-}" = 1 ]; then
      printf '%s\n' '{"tagName":"v1","assets":[{"name":"demo_1.0.0_amd64.deb"}]}'
    else
      printf '%s\n' '{"tagName":"v1","assets":[{"name":"demo_1.0.0_amd64.deb","digest":null}]}'
    fi
    ;;
  'release download')
    shift 2
    directory=''; pattern=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dir) directory=$2; shift 2 ;;
        --pattern) pattern=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'test package' > "$directory/$pattern"
    ;;
  'attestation verify')
    printf '%s\n' 'GH-ATTESTATION-SENTINEL: provenance lookup failed' >&2
    exit 42
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 99
    ;;
esac
SH
chmod +x "$work/bin/gh"

output=$(PATH="$work/bin:$PATH" "$root/scripts/fetch-packages.sh" \
  --manifest "$work/manifest.toml" --project demo --pool-dir "$work/pool" 2>&1)
status=$?
pass=0; fail=0
if [ "$status" -ne 0 ]; then pass=$((pass+1)); printf '  ok    Attestierungsfehler bricht ab\n'
else fail=$((fail+1)); printf '  FAIL  Attestierungsfehler bricht ab\n'; fi
if printf '%s' "$output" | grep -qF 'GH-ATTESTATION-SENTINEL'; then
  pass=$((pass+1)); printf '  ok    echte gh-Diagnose bleibt sichtbar\n'
else fail=$((fail+1)); printf '  FAIL  echte gh-Diagnose bleibt sichtbar\n'; fi
if printf '%s' "$output" | grep -qF 'attestation verification failed'; then
  pass=$((pass+1)); printf '  ok    Kontextmeldung folgt der gh-Diagnose\n'
else fail=$((fail+1)); printf '  FAIL  Kontextmeldung folgt der gh-Diagnose\n'; fi
missing=$(PATH="$work/bin:$PATH" FAKE_MISSING_DIGEST=1 \
  "$root/scripts/fetch-packages.sh" --manifest "$work/manifest.toml" \
  --project demo --pool-dir "$work/pool-missing" 2>&1)
missing_status=$?
if [ "$missing_status" -ne 0 ] && printf '%s' "$missing" | grep -qF 'selected asset carries no digest field'; then
  pass=$((pass+1)); printf '  ok    fehlendes Digest-Feld wird fail-closed behandelt\n'
else fail=$((fail+1)); printf '  FAIL  fehlendes Digest-Feld wird fail-closed behandelt\n'; fi

printf '\n  bestanden %d, fehlgeschlagen %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
