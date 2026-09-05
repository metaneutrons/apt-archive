#!/usr/bin/env bash
# Contract tests for the publication plan and the follow-up check.
#
# Part A checks the plan: order, object keys, rejections. Pure computation,
# without network and without credentials.
#
# Part B lays out the signed tree the way it would sit in the bucket, serves it
# locally and lets the follow-up check really run, tampering included. The
# upload itself stays untested, it needs R2.
set -uo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d /tmp/apt-archive-pub.XXXXXX)
export GNUPGHOME="$work/gnupg"
install -d -m 700 "$GNUPGHOME"
server_pid=''
cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
  gpgconf --homedir "$GNUPGHOME" --kill gpg-agent >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

PASS='x'; printf '%s' "$PASS" > "$work/pass"
G=(gpg --batch --pinentry-mode loopback --passphrase "$PASS")
"${G[@]}" --quick-generate-key 'pub test <p@example.invalid>' ed25519 cert never >/dev/null 2>&1
PRIMARY=$(gpg --list-keys --with-colons | awk -F: '$1=="fpr"{print $10; exit}')
"${G[@]}" --quick-add-key "$PRIMARY" ed25519 sign never >/dev/null 2>&1
"${G[@]}" --quick-add-key "$PRIMARY" ed25519 sign never >/dev/null 2>&1
SUBS=()
while IFS= read -r sub; do
  SUBS[${#SUBS[@]}]=$sub
done < <(gpg --list-keys --with-colons |
  awk -F: '$1=="sub"{s=1;next} $1=="fpr" && s{print $10; s=0}')
SUB=${SUBS[0]}
EPOCH=$(date +%s)
"${G[@]}" --export-secret-subkeys --armor "${SUB}!" > "$work/bundle.asc"

cat > "$work/m.toml" <<TOML
[domain]
layout = "shared-root-v1"
host = "deb.example.invalid"
base_url = "https://deb.example.invalid"
origin = "example"
keyring_package = "example-archive-keyring"
keyring_file = "/usr/share/keyrings/example-archive-keyring.pgp"

[signing]
primary_fingerprint = "$PRIMARY"
signing_subkey = "$SUB"

[publication]
r2_bucket = "example-deb"
r2_account_id = "00000000000000000000000000000000"

[release]
suite = "rolling"
codename = "rolling"
components = ["main"]
architectures = ["amd64", "arm64"]
acquire_by_hash = true
valid_until_days = 180

[[projects]]
name = "demo"
source_repo = "a/b"
packages = ["demo", "demo-doc"]
TOML

mkdir -p "$work/pool"
python3 "$root/tests/make_deb.py" --out "$work/pool/demo_1.0.0_amd64.deb" \
  --package demo --version 1.0.0 --architecture amd64
python3 "$root/tests/make_deb.py" --out "$work/pool/demo_1.0.0_arm64.deb" \
  --package demo --version 1.0.0 --architecture arm64
python3 "$root/tests/make_deb.py" --out "$work/pool/demo-doc_1.0.0_all.deb" \
  --package demo-doc --version 1.0.0 --architecture all --source demo

AR_RENDER_LOCAL=1 "$root/scripts/render-archive.sh" --manifest "$work/m.toml" \
  --project demo --pool-dir "$work/pool" --output-dir "$work/out" \
  --publication-epoch "$EPOCH" >/dev/null || { bad "setup: rendering"; exit 1; }

printf '\n== Workflow contract for the publication time ==\n'
workflow="$root/.github/workflows/publish.yml"
check "the workflow creates the epoch exactly once, internally" \
  "$(grep -c 'publication_epoch=$(date -u +%s)' "$workflow")" "1"
check "the workflow has no second shell source for the epoch" \
  "$(grep -Ec '^[[:space:]]*publication_epoch=' "$workflow")" "1"
check "the workflow exports exactly this epoch once, for later steps" \
  "$(grep -Fc "printf 'PUBLICATION_EPOCH=%s" "$workflow")" "1"
check "the renderer gets the local, internally created epoch" \
  "$(grep -Fc -- '--publication-epoch "$publication_epoch"' "$workflow")" "1"
check "signing, upload and follow-up check get the same epoch" \
  "$(grep -Fc -- '--publication-epoch "$PUBLICATION_EPOCH"' "$workflow")" "3"
check "the workflow uses no commit time for APT metadata" \
  "$(grep -Ec 'git (log|show)|head_commit|SOURCE_DATE_EPOCH|%[ac](t|I)' "$workflow")" "0"
check "a dispatch payload cannot feed in an epoch" \
  "$(grep -Eic '^[[:space:]]+(publication_)?epoch:|((client_payload|inputs).*(epoch|timestamp))|((epoch|timestamp).*(client_payload|inputs))' "$workflow")" "0"
check "secret lengths are not logged" \
  "$(grep -Ec 'present,.*bytes|wc -c.*(SECRET|KEY|PASS)' "$workflow")" "0"
check "R2 target validation comes before the first AWS call" \
  "$(WORKFLOW="$workflow" python3 - <<'PY'
import os
lines = open(os.environ["WORKFLOW"], encoding="utf-8").read().splitlines()
validator = next(i for i, line in enumerate(lines) if "publication_target.py" in line)
aws = next(i for i, line in enumerate(lines) if "aws s3api head-bucket" in line)
print("yes" if validator < aws else "no")
PY
)" "yes"
check "publication requests for the same domain are queued in full" \
  "$(grep -Ec '^[[:space:]]+queue: max$' "$workflow")" "1"

printf '\n== R2 target validation without credentials ==\n'
target_validator="$root/scripts/publication_target.py"
check "a valid target is read" \
  "$(python3 "$target_validator" --manifest "$work/m.toml" 2>/dev/null)" \
  "example-deb	00000000000000000000000000000000"
cp "$work/m.toml" "$work/bad-account.toml"
sed -i.bak 's/r2_account_id = .*/r2_account_id = "ABC"/' "$work/bad-account.toml"
msg=$(python3 "$target_validator" --manifest "$work/bad-account.toml" 2>&1)
if [ $? -ne 0 ] && printf '%s' "$msg" | grep -qF 'r2_account_id is malformed'; then
  ok "an invalid account ID is rejected before AWS"
else
  bad "an invalid account ID is rejected before AWS"
fi
cp "$work/m.toml" "$work/bad-bucket.toml"
sed -i.bak 's/r2_bucket = .*/r2_bucket = "Bad_Bucket"/' "$work/bad-bucket.toml"
msg=$(python3 "$target_validator" --manifest "$work/bad-bucket.toml" 2>&1)
if [ $? -ne 0 ] && printf '%s' "$msg" | grep -qF 'r2_bucket is malformed'; then
  ok "an invalid bucket is rejected before AWS"
else
  bad "an invalid bucket is rejected before AWS"
fi
check "the follow-up check demands gzip explicitly" \
  "$(grep -Ec '^exec python3' "$root/scripts/verify-publication.sh")" "1"
check "the subkey count masks no gpg error" \
  "$(grep -RE "grep -c '\^sub'.*\|\| true" \
      "$root/scripts/sign-archive.sh" "$root/scripts/verify-publication.sh" |
      wc -l | tr -d ' ')" "0"

printf '\n== Part A  The plan ==\n'
plan() { python3 "$root/scripts/publication_plan.py" --manifest "$work/m.toml" \
           --project demo --archive-dir "$work/out" \
           --publication-epoch "$EPOCH" 2>&1; }

msg=$(plan)
if printf '%s' "$msg" | grep -qF 'the archive is not signed'; then
  ok "an unsigned tree is rejected"
else
  bad "an unsigned tree is rejected" "$(printf '%s' "$msg" | head -1)"
fi

"$root/scripts/sign-archive.sh" --manifest "$work/m.toml" --archive-dir "$work/out" \
  --private-key "$work/bundle.asc" --passphrase-file "$work/pass" \
  --publication-epoch "$EPOCH" >/dev/null 2>&1 || { bad "setup: signing"; exit 1; }

p=$(plan)
check "phase order" \
  "$(printf '%s' "$p" | awk -F'\t' '{print $1}' | uniq | tr '\n' ' ')" \
  "keyring pool indexes release "
check "InRelease is the last entry" \
  "$(printf '%s' "$p" | tail -1 | awk -F'\t' '{print $3}')" \
  "dists/rolling/InRelease"
check "the keyring sits in the bucket root" \
  "$(printf '%s' "$p" | awk -F'\t' '$1=="keyring"{print $3}' | tr '\n' ' ')" \
  "example-archive-keyring.asc example-archive-keyring.pgp "
check "the pool runs at the domain root" \
  "$(printf '%s' "$p" | awk -F'\t' '$1=="pool"{print $3}' | grep -c '^pool/')" \
  "3"
check "no entry with a leading slash" \
  "$(printf '%s' "$p" | awk -F'\t' '$3 ~ /^\//' | wc -l | tr -d ' ')" "0"
check "packages carry the Debian media type" \
  "$(printf '%s' "$p" | awk -F'\t' '$1=="pool" && $4=="application/vnd.debian.binary-package"' | wc -l | tr -d ' ')" \
  "3"
check "by-hash with a fixed media type" \
  "$(printf '%s' "$p" | awk -F'\t' '$3 ~ /by-hash/ && $4!="application/octet-stream"' | wc -l | tr -d ' ')" \
  "0"
# Two local files must never point at one object key.
check "object keys are unique" \
  "$(printf '%s' "$p" | awk -F'\t' '{print $3}' | sort | uniq -d | wc -l | tr -d ' ')" "0"

printf '\n== Publication gate before the first upload ==\n'
stale_epoch=$((EPOCH - 7200))
stale="$work/stale"
cp -R "$work/out" "$stale"
RELEASE="$stale/dists/rolling/Release" STALE_EPOCH="$stale_epoch" python3 - <<'PY'
import datetime as dt
import os
from email.utils import format_datetime
from pathlib import Path

release = Path(os.environ["RELEASE"])
epoch = int(os.environ["STALE_EPOCH"])
stamp = lambda value: format_datetime(
    dt.datetime.fromtimestamp(value, tz=dt.timezone.utc)
)
lines = release.read_text().splitlines()
lines = [
    f"Date: {stamp(epoch)}" if line.startswith("Date: ") else
    f"Valid-Until: {stamp(epoch + 180 * 86400)}" if line.startswith("Valid-Until: ") else
    line
    for line in lines
]
release.write_text("\n".join(lines) + "\n")
PY
rm -f "$stale/dists/rolling/InRelease" "$stale/dists/rolling/Release.gpg"
"${G[@]}" --yes --local-user "${SUB}!" --armor --detach-sign \
  --output "$stale/dists/rolling/Release.gpg" "$stale/dists/rolling/Release" >/dev/null 2>&1
"${G[@]}" --yes --local-user "${SUB}!" --armor --clearsign \
  --output "$stale/dists/rolling/InRelease" "$stale/dists/rolling/Release" >/dev/null 2>&1
if gpgv --keyring "$stale/example-archive-keyring.pgp" \
    "$stale/dists/rolling/InRelease" >/dev/null 2>&1; then
  ok "the stale test version is cryptographically valid"
else
  bad "the stale test version is cryptographically valid"
fi

fake_bin="$work/fake-bin"; mkdir -p "$fake_bin"
cat > "$fake_bin/aws" <<'SH'
#!/bin/sh
operation=''; key=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    put-object|head-bucket|get-object|list-objects-v2) operation=$1; shift ;;
    --key) key=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$operation" = get-object ]; then
  printf 'An error occurred (NoSuchKey)' >&2; exit 1
elif [ "$operation" = list-objects-v2 ]; then
  printf '{"KeyCount":0,"IsTruncated":false}'; exit 0
fi
if [ "$operation" = put-object ]; then
  printf '%s\n' "$key" >> "$AWS_PUT_LOG"
  if [ -n "${AWS_FAIL_KEY:-}" ] && [ "$key" = "$AWS_FAIL_KEY" ]; then
    printf 'simulated upload failure for %s\n' "$key" >&2
    exit 1
  fi
fi
exit 0
SH
chmod +x "$fake_bin/aws"
printf '%s\n' '{"schema_version":1,"base_url":"https://deb.example.invalid","suite":"rolling","publication_epoch":0,"inrelease_sha256":null,"inrelease_etag":null}' > "$work/baseline.json"
: > "$work/put-attempts"
msg=$(PATH="$fake_bin:$PATH" AWS_PUT_LOG="$work/put-attempts" \
  R2_ACCESS_KEY_ID=test R2_SECRET_ACCESS_KEY=test \
  "$root/scripts/publish-archive.sh" --manifest "$work/m.toml" --project demo \
  --archive-dir "$stale" --publication-epoch "$stale_epoch" 2>&1)
publish_status=$?
if [ "$publish_status" -ne 0 ] && printf '%s' "$msg" | grep -qF 'maximum is 3600'; then
  ok "stale metadata are rejected by the real publisher"
else
  bad "stale metadata are rejected by the real publisher" "$(printf '%s' "$msg" | tail -1)"
fi
check "on rejection there was no put-object attempt" \
  "$(wc -l < "$work/put-attempts" | tr -d ' ')" "0"

printf '\n== The release phase stops at the first error ==\n'
: > "$work/release-attempts"
fail_key='dists/rolling/Release'
msg=$(PATH="$fake_bin:$PATH" AWS_PUT_LOG="$work/release-attempts" \
  AWS_FAIL_KEY="$fail_key" R2_ACCESS_KEY_ID=test R2_SECRET_ACCESS_KEY=test \
  "$root/scripts/publish-archive.sh" --manifest "$work/m.toml" --project demo \
  --archive-dir "$work/out" --publication-epoch "$EPOCH" --baseline "$work/baseline.json" 2>&1)
publish_status=$?
if [ "$publish_status" -ne 0 ] && printf '%s' "$msg" | grep -qF 'later metadata was not uploaded'; then
  ok "a release error aborts the phase by name"
else
  bad "a release error aborts the phase by name" "$(printf '%s' "$msg" | tail -1)"
fi
check "Release was attempted exactly once" \
  "$(grep -Fx "$fail_key" "$work/release-attempts" | wc -l | tr -d ' ')" "1"
check "Release.gpg was not attempted afterwards" \
  "$(grep -Fxc 'dists/rolling/Release.gpg' "$work/release-attempts")" "0"
check "InRelease was not attempted afterwards" \
  "$(grep -Fxc 'dists/rolling/InRelease' "$work/release-attempts")" "0"

printf '\n== Part B  Follow-up check against the served version ==\n'
srv="$work/serve"; mkdir -p "$srv"
cp "$work/out/example-archive-keyring.asc" "$work/out/example-archive-keyring.pgp" "$srv/"
cp -R "$work/out/dists" "$work/out/pool" "$srv/"

port=0
for candidate in $(seq 8100 8130); do
  if ! python3 -c "
import socket,sys
s=socket.socket()
try: s.bind(('127.0.0.1', $candidate))
except OSError: sys.exit(1)
s.close()" 2>/dev/null; then continue; fi
  port=$candidate; break
done
[ "$port" -ne 0 ] || { bad "no free port between 8100 and 8130"; exit 1; }
( cd "$srv" && exec python3 -m http.server "$port" >/dev/null 2>&1 ) &
server_pid=$!
for _ in $(seq 1 20); do
  python3 -c "
import urllib.request,sys
try: urllib.request.urlopen('http://127.0.0.1:$port/', timeout=1).read()
except Exception: sys.exit(1)" 2>/dev/null && break
  sleep 0.3
done

verify() { "$root/scripts/verify-publication.sh" --manifest "$work/m.toml" \
             --project demo --archive-dir "$work/out" \
             --publication-epoch "${1:-$EPOCH}" \
             --base-url "http://127.0.0.1:$port" 2>&1; }

if verify >/dev/null 2>&1; then ok "untouched: the follow-up check passes"
else bad "untouched: the follow-up check passes" "$(verify)"; fi

msg=$(verify "$((EPOCH + 1))")
if printf '%s' "$msg" | grep -qF 'does not equal publication epoch'; then
  ok "the follow-up check rejects a wrong expected epoch"
else
  bad "the follow-up check rejects a wrong expected epoch" "$(printf '%s' "$msg" | tail -1)"
fi

# This version is validly signed with the expected signature time but carries
# the wrong window. It therefore has to fail on the extracted Release, not
# already at gpgv and not only at the local byte comparison.
I="$srv/dists/rolling/InRelease"
cp "$I" "$work/k-time.inrel"
cp "$work/out/dists/rolling/Release" "$work/wrong-time.Release"
RELEASE="$work/wrong-time.Release" EPOCH="$EPOCH" python3 - <<'PY'
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
"${G[@]}" --yes --faked-system-time "${EPOCH}!" --local-user "${SUB}!" \
  --armor --clearsign --output "$I" "$work/wrong-time.Release" >/dev/null 2>&1
probe_msg=$(verify)
if printf '%s' "$probe_msg" | grep -qF 'object'; then
  ok "the follow-up check rejects a divergent public validity window"
else
  bad "the follow-up check tests the window in the signed public Release" \
    "$(printf '%s' "$probe_msg" | tail -1)"
fi
cp "$work/k-time.inrel" "$I"

# A different but validly signed version with the same time and index fields
# reaches step 3. Neither gpgv nor the later hash checks may pre-empt this
# conflict between generations.
cp "$I" "$work/k-generation.inrel"
cp "$work/out/dists/rolling/Release" "$work/other-generation.Release"
sed -i.bak 's/^Description: /Description: another generation of /' \
  "$work/other-generation.Release"
"${G[@]}" --yes --faked-system-time "${EPOCH}!" --local-user "${SUB}!" \
  --armor --clearsign --output "$I" "$work/other-generation.Release" >/dev/null 2>&1
probe_msg=$(verify)
if printf '%s' "$probe_msg" | grep -qF 'public object'; then
  ok "the follow-up check reaches and enforces the InRelease byte comparison"
else
  bad "the follow-up check reaches and enforces the InRelease byte comparison" \
    "$(printf '%s' "$probe_msg" | tail -1)"
fi
cp "$work/k-generation.inrel" "$I"

probe() {  # $1 = name, $2 = expected fragment
  local msg; msg=$(verify)
  if printf '%s' "$msg" | grep -qF "$2"; then ok "detects: $1"
  else bad "detects: $1" "$(printf '%s' "$msg" | tail -1)"; fi
}

D="$srv/pool/main/d/demo/demo_1.0.0_amd64.deb"
cp "$D" "$work/k.deb"; printf 'x' >> "$D"
probe "a tampered package" "public object"
cp "$work/k.deb" "$D"

# Counter-probe to the first: not the first package in the index but one of
# the later ones. A follow-up check that fetches only the first Filename entry
# falsely reports success here.
# The pool path depends on the source package name, hence searched for rather
# than wired in.
D2=$(find "$srv/pool" -name 'demo_1.0.0_arm64.deb' -print -quit)
[ -n "$D2" ] || bad "the arm64 package was not found in the served pool"
cp "$D2" "$work/k2.deb"; printf 'x' >> "$D2"
probe "a tampered package of a later architecture" "public object"
cp "$work/k2.deb" "$D2"

DA=$(find "$srv/pool" -name 'demo-doc_1.0.0_all.deb' -print -quit)
[ -n "$DA" ] || bad "the all package was not found in the served pool"
cp "$DA" "$work/ka.deb"; printf 'x' >> "$DA"
probe "a tampered architecture-independent package" "public object"
cp "$work/ka.deb" "$DA"

P="$srv/dists/rolling/main/binary-amd64/Packages.gz"
cp "$P" "$work/k.gz"; printf 'x' >> "$P"
probe "a tampered Packages.gz" "public object"
cp "$work/k.gz" "$P"

cp "$I" "$work/k.inrel"
python3 -c "
from pathlib import Path
p=Path('$I'); p.write_text(p.read_text().replace('Origin: example','Origin: evil'))"
probe "a tampered InRelease" "object"
cp "$work/k.inrel" "$I"

B="$srv/dists/rolling/main/binary-amd64/by-hash/SHA512/$(shasum -a 512 "$P" | cut -d' ' -f1)"
cp "$B" "$work/k.bh"; rm -f "$B"
probe "a missing by-hash file" "cannot fetch"
cp "$work/k.bh" "$B"

# The keyring has to be minimised to one subkey. The full certificate carries
# both and must not pass.
K="$srv/example-archive-keyring.pgp"
cp "$K" "$work/k.pgp"
gpg --no-options --batch --export > "$K" 2>/dev/null
probe "a keyring with both subkeys" "public object"
cp "$work/k.pgp" "$K"

if verify >/dev/null 2>&1; then ok "untouched again after every probe"
else bad "untouched again after every probe" "$(verify | tail -1)"; fi

printf '\n== A large index without SIGPIPE ==\n'
large_pool="$work/large-pool"; mkdir -p "$large_pool"
ROOT="$root" LARGE_POOL="$large_pool" python3 - <<'PY'
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(os.environ["ROOT"]) / "tests"))
from make_deb import build

pool = Path(os.environ["LARGE_POOL"])
for number in range(600):
    version = f"1.0.{number}"
    build(pool / f"demo_{version}_amd64.deb", {
        "Package": "demo",
        "Version": version,
        "Architecture": "amd64",
        "Maintainer": "Test <test@example.invalid>",
        "Description": "test package",
    })
PY
large="$work/large"
AR_RENDER_LOCAL=1 "$root/scripts/render-archive.sh" --manifest "$work/m.toml" \
  --project demo --pool-dir "$large_pool" --output-dir "$large" \
  --publication-epoch "$EPOCH" >/dev/null
"$root/scripts/sign-archive.sh" --manifest "$work/m.toml" --archive-dir "$large" \
  --private-key "$work/bundle.asc" --passphrase-file "$work/pass" \
  --publication-epoch "$EPOCH" >/dev/null 2>&1
large_packages="$large/dists/rolling/main/binary-amd64/Packages"
if [ "$(wc -c < "$large_packages" | tr -d ' ')" -gt 131072 ]; then
  ok "the test index is larger than two typical pipe buffers"
else
  bad "the test index is larger than two typical pipe buffers"
fi
rm -rf "$srv/demo/dists" "$srv/pool"
cp -R "$large/dists" "$large/pool" "$srv/"
large_msg=$("$root/scripts/verify-publication.sh" --manifest "$work/m.toml" \
  --project demo --archive-dir "$large" --publication-epoch "$EPOCH" \
  --base-url "http://127.0.0.1:$port" 2>&1)
if [ $? -eq 0 ]; then
  ok "the follow-up check consumes a large Packages index in full"
else
  bad "the follow-up check consumes a large Packages index in full" \
    "$(printf '%s' "$large_msg" | tail -1)"
fi

printf '\n  passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
