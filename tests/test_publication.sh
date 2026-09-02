#!/usr/bin/env bash
# Vertragstests fuer Veroeffentlichungsplan und Nachkontrolle.
#
# Teil A prueft den Plan: Reihenfolge, Objektschluessel, Ablehnungen. Reine
# Rechnung, ohne Netz und ohne Zugangsdaten.
#
# Teil B legt den signierten Baum so aus, wie er im Bucket liegen wuerde,
# liefert ihn lokal aus und laesst die Nachkontrolle wirklich laufen, samt
# Manipulationen. Der Upload selbst bleibt ungetestet, er braucht R2.
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
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "erwartet [$3], erhalten [$2]"; fi; }

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
prefix = "/demo"
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
  --publication-epoch "$EPOCH" >/dev/null || { bad "Aufbau: Rendern"; exit 1; }

printf '\n== Workflow-Vertrag fuer die Publikationszeit ==\n'
workflow="$root/.github/workflows/publish.yml"
check "Workflow erzeugt die Epoche genau einmal intern" \
  "$(grep -c 'publication_epoch=$(date -u +%s)' "$workflow")" "1"
check "Workflow hat keine zweite Shell-Quelle fuer die Epoche" \
  "$(grep -Ec '^[[:space:]]*publication_epoch=' "$workflow")" "1"
check "Workflow exportiert genau diese Epoche einmal fuer Folgeschritte" \
  "$(grep -Fc "printf 'PUBLICATION_EPOCH=%s" "$workflow")" "1"
check "Renderer bekommt die lokale, intern erzeugte Epoche" \
  "$(grep -Fc -- '--publication-epoch "$publication_epoch"' "$workflow")" "1"
check "Signatur, Upload und Nachkontrolle bekommen dieselbe Epoche" \
  "$(grep -Fc -- '--publication-epoch "$PUBLICATION_EPOCH"' "$workflow")" "3"
check "Workflow verwendet keine Commit-Zeit fuer APT-Metadaten" \
  "$(grep -Ec 'git (log|show)|head_commit|SOURCE_DATE_EPOCH|%[ac](t|I)' "$workflow")" "0"
check "Dispatch-Payload kann keine Epoche einspeisen" \
  "$(grep -Eic '^[[:space:]]+(publication_)?epoch:|((client_payload|inputs).*(epoch|timestamp))|((epoch|timestamp).*(client_payload|inputs))' "$workflow")" "0"
check "Secret-Laengen werden nicht protokolliert" \
  "$(grep -Ec 'present,.*bytes|wc -c.*(SECRET|KEY|PASS)' "$workflow")" "0"
check "R2-Zielvalidierung steht vor dem ersten AWS-Aufruf" \
  "$(WORKFLOW="$workflow" python3 - <<'PY'
import os
lines = open(os.environ["WORKFLOW"], encoding="utf-8").read().splitlines()
validator = next(i for i, line in enumerate(lines) if "publication_target.py" in line)
aws = next(i for i, line in enumerate(lines) if "aws s3api head-bucket" in line)
print("yes" if validator < aws else "no")
PY
)" "yes"
check "Publikationsanforderungen derselben Domain werden vollstaendig gequeued" \
  "$(grep -Ec '^[[:space:]]+queue: max$' "$workflow")" "1"

printf '\n== R2-Zielvalidierung ohne Credentials ==\n'
target_validator="$root/scripts/publication_target.py"
check "gueltiges Ziel wird gelesen" \
  "$(python3 "$target_validator" --manifest "$work/m.toml" 2>/dev/null)" \
  "example-deb	00000000000000000000000000000000"
cp "$work/m.toml" "$work/bad-account.toml"
sed -i.bak 's/r2_account_id = .*/r2_account_id = "ABC"/' "$work/bad-account.toml"
msg=$(python3 "$target_validator" --manifest "$work/bad-account.toml" 2>&1)
if [ $? -ne 0 ] && printf '%s' "$msg" | grep -qF 'r2_account_id is malformed'; then
  ok "ungueltige Account-ID wird vor AWS abgelehnt"
else
  bad "ungueltige Account-ID wird vor AWS abgelehnt"
fi
cp "$work/m.toml" "$work/bad-bucket.toml"
sed -i.bak 's/r2_bucket = .*/r2_bucket = "Bad_Bucket"/' "$work/bad-bucket.toml"
msg=$(python3 "$target_validator" --manifest "$work/bad-bucket.toml" 2>&1)
if [ $? -ne 0 ] && printf '%s' "$msg" | grep -qF 'r2_bucket is malformed'; then
  ok "ungueltiger Bucket wird vor AWS abgelehnt"
else
  bad "ungueltiger Bucket wird vor AWS abgelehnt"
fi
check "Nachkontrolle verlangt gzip explizit" \
  "$(grep -Ec '^for command in .*gzip' "$root/scripts/verify-publication.sh")" "1"
check "Subkey-Zaehlung maskiert keine gpg-Fehler" \
  "$(grep -RE "grep -c '\^sub'.*\|\| true" \
      "$root/scripts/sign-archive.sh" "$root/scripts/verify-publication.sh" |
      wc -l | tr -d ' ')" "0"

printf '\n== Teil A  Der Plan ==\n'
plan() { python3 "$root/scripts/publication_plan.py" --manifest "$work/m.toml" \
           --project demo --archive-dir "$work/out" \
           --publication-epoch "$EPOCH" 2>&1; }

msg=$(plan)
if printf '%s' "$msg" | grep -qF 'the archive is not signed'; then
  ok "unsignierter Baum wird abgelehnt"
else
  bad "unsignierter Baum wird abgelehnt" "$(printf '%s' "$msg" | head -1)"
fi

"$root/scripts/sign-archive.sh" --manifest "$work/m.toml" --archive-dir "$work/out" \
  --private-key "$work/bundle.asc" --passphrase-file "$work/pass" \
  --publication-epoch "$EPOCH" >/dev/null 2>&1 || { bad "Aufbau: Signieren"; exit 1; }

p=$(plan)
check "Phasenreihenfolge" \
  "$(printf '%s' "$p" | awk -F'\t' '{print $1}' | uniq | tr '\n' ' ')" \
  "keyring pool indexes release "
check "InRelease ist der letzte Eintrag" \
  "$(printf '%s' "$p" | tail -1 | awk -F'\t' '{print $3}')" \
  "demo/dists/rolling/InRelease"
check "Keyring liegt in der Bucket-Wurzel" \
  "$(printf '%s' "$p" | awk -F'\t' '$1=="keyring"{print $3}' | tr '\n' ' ')" \
  "example-archive-keyring.asc example-archive-keyring.pgp "
check "Pool laeuft unter dem Praefix" \
  "$(printf '%s' "$p" | awk -F'\t' '$1=="pool"{print $3}' | grep -c '^demo/pool/')" \
  "3"
check "kein Eintrag mit fuehrendem Schraegstrich" \
  "$(printf '%s' "$p" | awk -F'\t' '$3 ~ /^\//' | wc -l | tr -d ' ')" "0"
check "Pakete tragen den Debian-Medientyp" \
  "$(printf '%s' "$p" | awk -F'\t' '$1=="pool" && $4=="application/vnd.debian.binary-package"' | wc -l | tr -d ' ')" \
  "3"
check "by-hash mit festem Medientyp" \
  "$(printf '%s' "$p" | awk -F'\t' '$3 ~ /by-hash/ && $4!="application/octet-stream"' | wc -l | tr -d ' ')" \
  "0"
# Zwei lokale Dateien duerfen nie auf einen Objektschluessel zeigen.
check "Objektschluessel sind eindeutig" \
  "$(printf '%s' "$p" | awk -F'\t' '{print $3}' | sort | uniq -d | wc -l | tr -d ' ')" "0"

printf '\n== Publikations-Gate vor dem ersten Upload ==\n'
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
  ok "veraltete Testfassung ist kryptografisch gueltig"
else
  bad "veraltete Testfassung ist kryptografisch gueltig"
fi

fake_bin="$work/fake-bin"; mkdir -p "$fake_bin"
cat > "$fake_bin/aws" <<'SH'
#!/bin/sh
operation=''; key=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    put-object|head-bucket) operation=$1; shift ;;
    --key) key=$2; shift 2 ;;
    *) shift ;;
  esac
done
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
: > "$work/put-attempts"
msg=$(PATH="$fake_bin:$PATH" AWS_PUT_LOG="$work/put-attempts" \
  R2_ACCESS_KEY_ID=test R2_SECRET_ACCESS_KEY=test \
  "$root/scripts/publish-archive.sh" --manifest "$work/m.toml" --project demo \
  --archive-dir "$stale" --publication-epoch "$stale_epoch" 2>&1)
publish_status=$?
if [ "$publish_status" -ne 0 ] && printf '%s' "$msg" | grep -qF 'maximum is 3600'; then
  ok "alte Metadaten werden vom echten Publisher abgelehnt"
else
  bad "alte Metadaten werden vom echten Publisher abgelehnt" "$(printf '%s' "$msg" | tail -1)"
fi
check "bei Ablehnung gab es keinen put-object-Versuch" \
  "$(wc -l < "$work/put-attempts" | tr -d ' ')" "0"

printf '\n== Release-Phase stoppt beim ersten Fehler ==\n'
: > "$work/release-attempts"
fail_key='demo/dists/rolling/Release'
msg=$(PATH="$fake_bin:$PATH" AWS_PUT_LOG="$work/release-attempts" \
  AWS_FAIL_KEY="$fail_key" R2_ACCESS_KEY_ID=test R2_SECRET_ACCESS_KEY=test \
  "$root/scripts/publish-archive.sh" --manifest "$work/m.toml" --project demo \
  --archive-dir "$work/out" --publication-epoch "$EPOCH" 2>&1)
publish_status=$?
if [ "$publish_status" -ne 0 ] && printf '%s' "$msg" | grep -qF 'later metadata was not uploaded'; then
  ok "Release-Fehler bricht die Phase benannt ab"
else
  bad "Release-Fehler bricht die Phase benannt ab" "$(printf '%s' "$msg" | tail -1)"
fi
check "Release wurde genau einmal versucht" \
  "$(grep -Fx "$fail_key" "$work/release-attempts" | wc -l | tr -d ' ')" "1"
check "Release.gpg wurde danach nicht versucht" \
  "$(grep -Fxc 'demo/dists/rolling/Release.gpg' "$work/release-attempts")" "0"
check "InRelease wurde danach nicht versucht" \
  "$(grep -Fxc 'demo/dists/rolling/InRelease' "$work/release-attempts")" "0"

printf '\n== Teil B  Nachkontrolle gegen die ausgelieferte Fassung ==\n'
srv="$work/serve"; mkdir -p "$srv/demo"
cp "$work/out/example-archive-keyring.asc" "$work/out/example-archive-keyring.pgp" "$srv/"
cp -R "$work/out/dists" "$work/out/pool" "$srv/demo/"

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
[ "$port" -ne 0 ] || { bad "kein freier Port zwischen 8100 und 8130"; exit 1; }
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

if verify >/dev/null 2>&1; then ok "unveraendert: Nachkontrolle laeuft durch"
else bad "unveraendert: Nachkontrolle laeuft durch" "$(verify)"; fi

msg=$(verify "$((EPOCH + 1))")
if printf '%s' "$msg" | grep -qF 'does not equal publication epoch'; then
  ok "Nachkontrolle lehnt eine falsche erwartete Epoche ab"
else
  bad "Nachkontrolle lehnt eine falsche erwartete Epoche ab" "$(printf '%s' "$msg" | tail -1)"
fi

# Diese Fassung ist gueltig mit der erwarteten Signaturzeit signiert, traegt
# aber eine falsche Frist. Sie muss deshalb am extrahierten Release scheitern,
# nicht schon an gpgv oder erst am lokalen Bytevergleich.
I="$srv/demo/dists/rolling/InRelease"
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
if printf '%s' "$probe_msg" | grep -qF 'Valid-Until is not exactly 180 days'; then
  ok "Nachkontrolle prueft die Frist im signierten oeffentlichen Release"
else
  bad "Nachkontrolle prueft die Frist im signierten oeffentlichen Release" \
    "$(printf '%s' "$probe_msg" | tail -1)"
fi
cp "$work/k-time.inrel" "$I"

# Eine andere, aber gueltig signierte Fassung mit denselben Zeit- und
# Indexfeldern erreicht Schritt 3. Weder gpgv noch die spaeteren Hashpruefungen
# duerfen diesen Generationenkonflikt vorwegnehmen.
cp "$I" "$work/k-generation.inrel"
cp "$work/out/dists/rolling/Release" "$work/other-generation.Release"
sed -i.bak 's/^Description: /Description: andere Generation von /' \
  "$work/other-generation.Release"
"${G[@]}" --yes --faked-system-time "${EPOCH}!" --local-user "${SUB}!" \
  --armor --clearsign --output "$I" "$work/other-generation.Release" >/dev/null 2>&1
probe_msg=$(verify)
if printf '%s' "$probe_msg" | grep -qF 'published InRelease differs from the local one'; then
  ok "Nachkontrolle erreicht und erzwingt den InRelease-Bytevergleich"
else
  bad "Nachkontrolle erreicht und erzwingt den InRelease-Bytevergleich" \
    "$(printf '%s' "$probe_msg" | tail -1)"
fi
cp "$work/k-generation.inrel" "$I"

probe() {  # $1 = Name, $2 = erwartetes Fragment
  local msg; msg=$(verify)
  if printf '%s' "$msg" | grep -qF "$2"; then ok "erkennt: $1"
  else bad "erkennt: $1" "$(printf '%s' "$msg" | tail -1)"; fi
}

D="$srv/demo/pool/main/d/demo/demo_1.0.0_amd64.deb"
cp "$D" "$work/k.deb"; printf 'x' >> "$D"
probe "veraendertes Paket" "differs from the local file"
cp "$work/k.deb" "$D"

P="$srv/demo/dists/rolling/main/binary-amd64/Packages.gz"
cp "$P" "$work/k.gz"; printf 'x' >> "$P"
probe "veraendertes Packages.gz" "does not match its SHA256"
cp "$work/k.gz" "$P"

cp "$I" "$work/k.inrel"
python3 -c "
from pathlib import Path
p=Path('$I'); p.write_text(p.read_text().replace('Origin: example','Origin: evil'))"
probe "veraendertes InRelease" "gpgv rejected the published InRelease"
cp "$work/k.inrel" "$I"

B="$srv/demo/dists/rolling/main/binary-amd64/by-hash/SHA512/$(shasum -a 512 "$P" | cut -d' ' -f1)"
cp "$B" "$work/k.bh"; rm -f "$B"
probe "fehlende by-hash-Datei" "cannot fetch"
cp "$work/k.bh" "$B"

# Der Keyring muss auf einen Subkey minimiert sein. Das vollstaendige
# Zertifikat traegt beide und darf nicht durchgehen.
K="$srv/example-archive-keyring.pgp"
cp "$K" "$work/k.pgp"
gpg --no-options --batch --export > "$K" 2>/dev/null
probe "Keyring mit beiden Subkeys" "carries 2 subkeys"
cp "$work/k.pgp" "$K"

if verify >/dev/null 2>&1; then ok "nach allen Proben wieder unveraendert"
else bad "nach allen Proben wieder unveraendert" "$(verify | tail -1)"; fi

printf '\n== Grosser Index ohne SIGPIPE ==\n'
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
  ok "Testindex ist groesser als zwei typische Pipe-Puffer"
else
  bad "Testindex ist groesser als zwei typische Pipe-Puffer"
fi
rm -rf "$srv/demo/dists" "$srv/demo/pool"
cp -R "$large/dists" "$large/pool" "$srv/demo/"
large_msg=$("$root/scripts/verify-publication.sh" --manifest "$work/m.toml" \
  --project demo --archive-dir "$large" --publication-epoch "$EPOCH" \
  --base-url "http://127.0.0.1:$port" 2>&1)
if [ $? -eq 0 ]; then
  ok "Nachkontrolle verbraucht grossen Packages-Index vollstaendig"
else
  bad "Nachkontrolle verbraucht grossen Packages-Index vollstaendig" \
    "$(printf '%s' "$large_msg" | tail -1)"
fi

printf '\n  bestanden %d, fehlgeschlagen %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
