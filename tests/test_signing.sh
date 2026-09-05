#!/usr/bin/env bash
# Contract tests for the signature. Creates a throwaway key in the shape the
# standard prescribes: a certifying Ed25519 primary plus one signing subkey per
# archive domain. No network, no real key material.
set -uo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d /tmp/apt-archive-test.XXXXXX)
export GNUPGHOME="$work/gnupg"
install -d -m 700 "$GNUPGHOME"
cleanup() {
  gpgconf --homedir "$GNUPGHOME" --kill gpg-agent >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
upper() { printf '%s' "$1" | LC_ALL=C tr '[:lower:]' '[:upper:]'; }

PASS='testpassphrase'
printf '%s' "$PASS" > "$work/pass"
G=(gpg --batch --pinentry-mode loopback --passphrase "$PASS")

printf '\n== Key in the prescribed shape ==\n'
"${G[@]}" --quick-generate-key 'apt-archive test <t@example.invalid>' ed25519 cert never >/dev/null 2>&1
PRIMARY=$(gpg --list-keys --with-colons | awk -F: '$1=="fpr"{print $10; exit}')
"${G[@]}" --quick-add-key "$PRIMARY" ed25519 sign never >/dev/null 2>&1
"${G[@]}" --quick-add-key "$PRIMARY" ed25519 sign never >/dev/null 2>&1
SUBS=()
while IFS= read -r sub; do
  SUBS[${#SUBS[@]}]=$sub
done < <(gpg --list-keys --with-colons |
  awk -F: '$1=="sub"{s=1;next} $1=="fpr" && s{print $10; s=0}')
SUB_A=${SUBS[0]}; SUB_B=${SUBS[1]}
# Only now, because gpg does not sign with a key that does not yet exist as
# far as the faked time is concerned. The test found a one-second difference
# here when the epoch was taken before key creation.
EPOCH=$(date +%s)

check "primary is certify-only" \
  "$(gpg --list-keys --with-colons | awk -F: '$1=="pub"{print $12; exit}')" "cSC"
check "two signing subkeys" "${#SUBS[@]}" "2"

# Export of the secret subkeys only. The exclamation mark pins one of them.
"${G[@]}" --export-secret-subkeys --armor "${SUB_A}!" > "$work/bundle-a.asc"
"${G[@]}" --export-secret-subkeys --armor "${SUB_B}!" > "$work/bundle-b.asc"
"${G[@]}" --export-secret-keys --armor "$PRIMARY" > "$work/bundle-full.asc"
# Both secret subkeys in one bundle. Without this fixture the pinning by
# exclamation mark cannot be checked: with only one subkey gpg cannot pick
# wrongly even unpinned, and the export contains only one anyway.
"${G[@]}" --export-secret-subkeys --armor "$PRIMARY" > "$work/bundle-both.asc"

manifest() {  # $1 = target, $2 = primary, $3 = subkey
  cat > "$1" <<TOML
[domain]
host = "deb.example.invalid"
base_url = "https://deb.example.invalid"
origin = "example"
keyring_package = "example-archive-keyring"
keyring_file = "/usr/share/keyrings/example-archive-keyring.pgp"

[signing]
primary_fingerprint = "$2"
signing_subkey = "$3"

[publication]
r2_bucket = "b"
r2_account_id = "0"

[release]
suite = "rolling"
codename = "rolling"
components = ["main"]
architectures = ["amd64"]
acquire_by_hash = true
valid_until_days = 180

[[projects]]
name = "demo"
prefix = "/demo"
source_repo = "a/b"
packages = ["demo"]
TOML
}

render() {  # $1 = output directory
  local pool="$work/pool"
  if [ ! -d "$pool" ]; then
    mkdir -p "$pool"
    python3 "$root/tests/make_deb.py" --out "$pool/demo_1.0.0_amd64.deb" \
      --package demo --version 1.0.0 --architecture amd64
  fi
  manifest "$work/m.toml" "$PRIMARY" "$SUB_A"
  AR_RENDER_LOCAL=1 "$root/scripts/render-archive.sh" --manifest "$work/m.toml" \
    --project demo --pool-dir "$pool" --output-dir "$1" --publication-epoch "${2:-$EPOCH}" >/dev/null
}

sign() {  # $1 = archive directory, $2 = manifest, $3 = bundle, $4 optional = epoch
  "$root/scripts/sign-archive.sh" --manifest "$2" --archive-dir "$1" \
    --private-key "$3" --passphrase-file "$work/pass" \
    --publication-epoch "${4:-$EPOCH}" 2>&1
}

printf '\n== T1  Signing with the subkey of the domain ==\n'
A="$work/a"; render "$A"
manifest "$work/m.toml" "$PRIMARY" "$SUB_A"
out=$(sign "$A" "$work/m.toml" "$work/bundle-a.asc")
if [ $? -ne 0 ]; then bad "T1 signature" "$out"; else
  ok "T1 signing runs"
  check "T1 InRelease present"   "$([ -f "$A/dists/rolling/InRelease" ] && echo yes || echo no)" "yes"
  check "T1 Release.gpg present" "$([ -f "$A/dists/rolling/Release.gpg" ] && echo yes || echo no)" "yes"
  check "T1 keyring dearmored"   "$([ -f "$A/example-archive-keyring.pgp" ] && echo yes || echo no)" "yes"
  check "T1 keyring armored"     "$([ -f "$A/example-archive-keyring.asc" ] && echo yes || echo no)" "yes"
  check "T1 keyring carries exactly one subkey" \
    "$(gpg --no-options --batch --with-colons --show-keys "$A/example-archive-keyring.pgp" | grep -c '^sub')" "1"
  # It has to be the right subkey, not just any one.
  check "T1 and it is subkey A" \
    "$(gpg --no-options --batch --with-colons --show-keys "$A/example-archive-keyring.pgp" |
       awk -F: '$1=="sub"{s=1;next} $1=="fpr" && s{print toupper($10); exit}')" "$(upper "$SUB_A")"
  signer=$(gpgv --keyring "$A/example-archive-keyring.pgp" --status-fd 1 \
             "$A/dists/rolling/InRelease" 2>/dev/null | awk '/VALIDSIG/{print $3}')
  check "T1 subkey A did the signing" "$(upper "$signer")" "$(upper "$SUB_A")"
  inrelease_epoch=$(gpgv --keyring "$A/example-archive-keyring.pgp" --status-fd 1 \
              "$A/dists/rolling/InRelease" 2>/dev/null | awk '/VALIDSIG/{print $5}')
  detached_epoch=$(gpgv --keyring "$A/example-archive-keyring.pgp" --status-fd 1 \
              "$A/dists/rolling/Release.gpg" "$A/dists/rolling/Release" 2>/dev/null |
              awk '/VALIDSIG/{print $5}')
  check "T1 the InRelease signature uses the publication epoch" "$inrelease_epoch" "$EPOCH"
  check "T1 the Release.gpg signature uses the publication epoch" "$detached_epoch" "$EPOCH"
fi

printf '\n== T2  Determinism ==\n'
# Only meaningful if T1 really signed: otherwise the test compares two
# unsigned trees and is green without checking anything.
if [ -f "$A/dists/rolling/InRelease" ]; then
  B="$work/b"; render "$B"
  if sign "$B" "$work/m.toml" "$work/bundle-a.asc" >/dev/null; then
    if diff -r "$A" "$B" >/dev/null 2>&1; then ok "T2 two runs byte-identical"
    else bad "T2 two runs byte-identical" "$(diff -rq "$A" "$B" 2>&1 | head -3)"; fi
  else
    bad "T2 two runs byte-identical" "the second signing run failed"
  fi
else
  bad "T2 two runs byte-identical" "skipped, T1 did not sign"
fi

printf '\n== T2b  A new publication changes only signed metadata ==\n'
while [ "$(date +%s)" -le "$EPOCH" ]; do sleep 0.1; done
LATER_EPOCH=$(date +%s)
C="$work/c"; render "$C" "$LATER_EPOCH"
if sign "$C" "$work/m.toml" "$work/bundle-a.asc" "$LATER_EPOCH" >/dev/null; then
  content_manifest() {  # $1 = archive root; leave out the signed metadata
    (cd "$1" && find . -type f | sort | while IFS= read -r path; do
      case "$path" in
        ./dists/rolling/Release|./dists/rolling/Release.gpg|./dists/rolling/InRelease) continue ;;
      esac
      shasum -a 256 "$path" | awk -v path="$path" '{print $1, path}'
    done)
  }
  content_manifest "$A" > "$work/content-a.sha256"
  content_manifest "$C" > "$work/content-c.sha256"
  if cmp -s "$work/content-a.sha256" "$work/content-c.sha256"; then
    ok "T2b every other path and byte stays untouched"
  else
    bad "T2b every other path and byte stays untouched" \
      "$(diff -u "$work/content-a.sha256" "$work/content-c.sha256" | head -12)"
  fi
  for path in pool dists/rolling/main example-archive-keyring.asc example-archive-keyring.pgp; do
    if diff -r "$A/$path" "$C/$path" >/dev/null 2>&1; then
      ok "T2b a new epoch leaves $path untouched"
    else
      bad "T2b a new epoch leaves $path untouched"
    fi
  done
  for name in Release Release.gpg InRelease; do
    if cmp -s "$A/dists/rolling/$name" "$C/dists/rolling/$name"; then
      bad "T2b a new epoch changes $name"
    else
      ok "T2b a new epoch changes $name"
    fi
  done
  if diff <(sed '/^Date: /d; /^Valid-Until: /d' "$A/dists/rolling/Release") \
          <(sed '/^Date: /d; /^Valid-Until: /d' "$C/dists/rolling/Release") \
          >/dev/null 2>&1; then
    ok "T2b Release differs only in Date and Valid-Until"
  else
    bad "T2b Release differs only in Date and Valid-Until"
  fi
  later_signature_epoch=$(gpgv --keyring "$C/example-archive-keyring.pgp" --status-fd 1 \
      "$C/dists/rolling/InRelease" 2>/dev/null | awk '/VALIDSIG/{print $5}')
  check "T2b the new signature uses the new epoch" "$later_signature_epoch" "$LATER_EPOCH"
else
  bad "T2b a new publication can be signed"
fi

printf '\n== T3  Rejections ==\n'
reject() {  # $1 = name, $2 = text fragment, $3 = manifest, $4 = bundle
  local d="$work/r.$RANDOM"; render "$d"
  local msg; msg=$(sign "$d" "$3" "$4")
  if printf '%s' "$msg" | grep -qF "$2"; then ok "T3 $1"
  else bad "T3 $1" "expected [$2], got: $(printf '%s' "$msg" | head -1)"; fi
}
manifest "$work/m-wrong.toml" "$PRIMARY" "$SUB_B"
reject "a foreign subkey is rejected" "not in the bundle" "$work/m-wrong.toml" "$work/bundle-a.asc"
reject "a bundle with the secret primary is rejected" "primary secret key is present" "$work/m.toml" "$work/bundle-full.asc"
manifest "$work/m-tbd.toml" "$PRIMARY" "$SUB_A"
sed -i.bak 's/^signing_subkey = .*/signing_subkey = "TBD"/' "$work/m-tbd.toml"
reject "TBD in the manifest is rejected" "usable signing values" "$work/m-tbd.toml" "$work/bundle-a.asc"
manifest "$work/m-badprim.toml" "${SUB_B}" "$SUB_A"
reject "the wrong primary is rejected" "manifest names" "$work/m-badprim.toml" "$work/bundle-a.asc"

printf '\n== T4  Pinning with two subkeys in the bundle ==\n'
# The actual centrepiece. With both domain subkeys in the bundle, exactly the
# one from the manifest still has to sign, and the keyring may contain only
# that one.
# A secret-key export lists subkeys as ssb, not as sub.
check "T4 the bundle contains two secret subkeys" \
  "$(gpg --no-options --batch --with-colons --show-keys "$work/bundle-both.asc" | grep -c '^ssb')" "2"
D="$work/d"; render "$D"
manifest "$work/m.toml" "$PRIMARY" "$SUB_A"
out=$(sign "$D" "$work/m.toml" "$work/bundle-both.asc")
if [ $? -ne 0 ]; then bad "T4 signing with a two-subkey bundle" "$out"; else
  ok "T4 signing runs"
  check "T4 keyring carries exactly one subkey" \
    "$(gpg --no-options --batch --with-colons --show-keys "$D/example-archive-keyring.pgp" | grep -c '^sub')" "1"
  check "T4 and it is subkey A" \
    "$(gpg --no-options --batch --with-colons --show-keys "$D/example-archive-keyring.pgp" |
       awk -F: '$1=="sub"{s=1;next} $1=="fpr" && s{print toupper($10); exit}')" "$(upper "$SUB_A")"
  signer=$(gpgv --keyring "$D/example-archive-keyring.pgp" --status-fd 1 \
             "$D/dists/rolling/InRelease" 2>/dev/null | awk '/VALIDSIG/{print $3}')
  check "T4 subkey A did the signing, not B" "$(upper "$signer")" "$(upper "$SUB_A")"
  # The armored keyring ships just the same. Without an assertion of its own,
  # an unpinned export would stay unnoticed there.
  check "T4 armored keyring carries exactly one subkey" \
    "$(gpg --no-options --batch --with-colons --show-keys "$D/example-archive-keyring.asc" | grep -c '^sub')" "1"
  check "T4 armored keyring lists subkey A" \
    "$(gpg --no-options --batch --with-colons --show-keys "$D/example-archive-keyring.asc" |
       awk -F: '$1=="sub"{s=1;next} $1=="fpr" && s{print toupper($10); exit}')" "$(upper "$SUB_A")"
  # Both versions have to be the same certificate. Compare the fingerprints
  # directly rather than their hash: `md5` exists only on macOS, GNU systems
  # have `md5sum`, and a hash buys nothing when comparing two text lists.
  check "T4 armored and dearmored coincide" \
    "$(gpg --no-options --batch --with-colons --show-keys "$D/example-archive-keyring.asc" | awk -F: '$1=="fpr"{print $10}' | sort | tr '\n' ' ')" \
    "$(gpg --no-options --batch --with-colons --show-keys "$D/example-archive-keyring.pgp" | awk -F: '$1=="fpr"{print $10}' | sort | tr '\n' ' ')"
  # Counter-probe: the same tree, but the manifest on B. Then B has to sign.
  E="$work/e"; render "$E"
  manifest "$work/m-b.toml" "$PRIMARY" "$SUB_B"
  if sign "$E" "$work/m-b.toml" "$work/bundle-both.asc" >/dev/null; then
    signer=$(gpgv --keyring "$E/example-archive-keyring.pgp" --status-fd 1 \
               "$E/dists/rolling/InRelease" 2>/dev/null | awk '/VALIDSIG/{print $3}')
    check "T4 the manifest on B lets B sign" "$(upper "$signer")" "$(upper "$SUB_B")"
  else
    bad "T4 the manifest on B lets B sign" "the signing run failed"
  fi
fi

printf '\n== T5  Epoch before key creation ==\n'
# One second before the actual subkey creation stays inside the freshness
# window and thereby isolates exactly the key check.
created=$(gpg --with-colons --list-keys "$SUB_A" | awk -F: '$1 == "sub" {print $6; exit}')
before_key=$((created - 1))
F="$work/f"; render "$F" "$before_key"
msg=$(sign "$F" "$work/m.toml" "$work/bundle-a.asc" "$before_key")
if printf '%s' "$msg" | grep -qF 'precedes the subkey creation'; then
  ok "T5 an epoch that is too early is rejected by name"
else
  bad "T5 an epoch that is too early is rejected by name" "$(printf '%s' "$msg" | head -1)"
fi

printf '\n== T6  The time model rejects contradiction, age and the future ==\n'
M="$work/mismatch"; render "$M"
msg=$(sign "$M" "$work/m.toml" "$work/bundle-a.asc" "$((EPOCH + 1))")
if printf '%s' "$msg" | grep -qF 'Release Date does not equal publication epoch'; then
  ok "T6 render and signature epoch have to agree"
else
  bad "T6 render and signature epoch have to agree" "$(printf '%s' "$msg" | head -1)"
fi

stale_epoch=$((EPOCH - 7200))
S="$work/stale"; render "$S" "$stale_epoch"
msg=$(sign "$S" "$work/m.toml" "$work/bundle-a.asc" "$stale_epoch")
if printf '%s' "$msg" | grep -qF 'maximum is 3600'; then
  ok "T6 a two-hour-old publication epoch is rejected"
else
  bad "T6 a two-hour-old publication epoch is rejected" "$(printf '%s' "$msg" | head -1)"
fi

future_epoch=$((EPOCH + 3600))
U="$work/future"; render "$U" "$future_epoch"
msg=$(sign "$U" "$work/m.toml" "$work/bundle-a.asc" "$future_epoch")
if printf '%s' "$msg" | grep -qF 'is in the future'; then
  ok "T6 a publication epoch in the future is rejected"
else
  bad "T6 a publication epoch in the future is rejected" "$(printf '%s' "$msg" | head -1)"
fi

V="$work/bad-valid-until"; render "$V"
RELEASE="$V/dists/rolling/Release" EPOCH="$EPOCH" python3 - <<'PY'
import datetime as dt
import os
from email.utils import format_datetime
from pathlib import Path

release = Path(os.environ["RELEASE"])
wrong = dt.datetime.fromtimestamp(
    int(os.environ["EPOCH"]) + 181 * 86400, tz=dt.timezone.utc
)
wrong = format_datetime(wrong)
lines = release.read_text().splitlines()
release.write_text("\n".join(
    f"Valid-Until: {wrong}" if line.startswith("Valid-Until: ") else line
    for line in lines
) + "\n")
PY
msg=$(sign "$V" "$work/m.toml" "$work/bundle-a.asc")
if printf '%s' "$msg" | grep -qF 'Valid-Until is not exactly 180 days'; then
  ok "T6 a wrong Valid-Until window is rejected"
else
  bad "T6 a wrong Valid-Until window is rejected" "$(printf '%s' "$msg" | head -1)"
fi

printf '\n  passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
