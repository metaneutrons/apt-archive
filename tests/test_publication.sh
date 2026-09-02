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
mapfile -t SUBS < <(gpg --list-keys --with-colons |
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
  --metadata-epoch "$EPOCH" >/dev/null || { bad "Aufbau: Rendern"; exit 1; }

printf '\n== Teil A  Der Plan ==\n'
plan() { python3 "$root/scripts/publication_plan.py" --manifest "$work/m.toml" \
           --project demo --archive-dir "$work/out" 2>&1; }

msg=$(plan)
if printf '%s' "$msg" | grep -qF 'the archive is not signed'; then
  ok "unsignierter Baum wird abgelehnt"
else
  bad "unsignierter Baum wird abgelehnt" "$(printf '%s' "$msg" | head -1)"
fi

"$root/scripts/sign-archive.sh" --manifest "$work/m.toml" --archive-dir "$work/out" \
  --private-key "$work/bundle.asc" --passphrase-file "$work/pass" \
  --metadata-epoch "$EPOCH" >/dev/null 2>&1 || { bad "Aufbau: Signieren"; exit 1; }

p=$(plan)
check "Phasenreihenfolge" \
  "$(printf '%s' "$p" | awk -F'\t' '{print $1}' | uniq | tr '\n' ' ')" \
  "keyring pool indexes release "
check "InRelease ist der letzte Eintrag" \
  "$(printf '%s' "$p" | tail -1 | awk -F'\t' '{print $3}')" \
  "demo/dists/rolling/InRelease"
check "Keyring liegt in der Bucket-Wurzel" \
  "$(printf '%s' "$p" | awk -F'\t' '$1=="keyring"{print $3}' | tr '\n' ' ')" \
  "example-archive-keyring.asc example-archive-keyring.gpg "
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

printf '\n== Teil B  Nachkontrolle gegen die ausgelieferte Fassung ==\n'
srv="$work/serve"; mkdir -p "$srv/demo"
cp "$work/out/example-archive-keyring.asc" "$work/out/example-archive-keyring.gpg" "$srv/"
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
             --base-url "http://127.0.0.1:$port" 2>&1; }

if verify >/dev/null 2>&1; then ok "unveraendert: Nachkontrolle laeuft durch"
else bad "unveraendert: Nachkontrolle laeuft durch" "$(verify | tail -1)"; fi

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

I="$srv/demo/dists/rolling/InRelease"
cp "$I" "$work/k.inrel"
python3 -c "
from pathlib import Path
p=Path('$I'); p.write_text(p.read_text().replace('Origin: example','Origin: evil'))"
probe "veraendertes InRelease" "gpgv rejected the published InRelease"
cp "$work/k.inrel" "$I"

B=$(find "$srv/demo/dists/rolling/main/binary-amd64/by-hash/SHA512" -type f | head -1)
cp "$B" "$work/k.bh"; rm -f "$B"
probe "fehlende by-hash-Datei" "cannot fetch"
cp "$work/k.bh" "$B"

# Der Keyring muss auf einen Subkey minimiert sein. Das vollstaendige
# Zertifikat traegt beide und darf nicht durchgehen.
K="$srv/example-archive-keyring.gpg"
cp "$K" "$work/k.gpg"
gpg --no-options --batch --export > "$K" 2>/dev/null
probe "Keyring mit beiden Subkeys" "carries 2 subkeys"
cp "$work/k.gpg" "$K"

if verify >/dev/null 2>&1; then ok "nach allen Proben wieder unveraendert"
else bad "nach allen Proben wieder unveraendert" "$(verify | tail -1)"; fi

printf '\n  bestanden %d, fehlgeschlagen %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
