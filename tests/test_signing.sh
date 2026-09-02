#!/usr/bin/env bash
# Vertragstests fuer die Signatur. Erzeugt einen Wegwerfschluessel in der Form,
# die der Standard vorschreibt: zertifizierender Ed25519-Primaer und je
# Archiv-Domain ein Signing-Subkey. Kein Netz, kein echtes Schluesselmaterial.
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
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "erwartet [$3], erhalten [$2]"; fi; }

PASS='testpassphrase'
printf '%s' "$PASS" > "$work/pass"
G=(gpg --batch --pinentry-mode loopback --passphrase "$PASS")

printf '\n== Schluessel in der vorgeschriebenen Form ==\n'
"${G[@]}" --quick-generate-key 'apt-archive test <t@example.invalid>' ed25519 cert never >/dev/null 2>&1
PRIMARY=$(gpg --list-keys --with-colons | awk -F: '$1=="fpr"{print $10; exit}')
"${G[@]}" --quick-add-key "$PRIMARY" ed25519 sign never >/dev/null 2>&1
"${G[@]}" --quick-add-key "$PRIMARY" ed25519 sign never >/dev/null 2>&1
mapfile -t SUBS < <(gpg --list-keys --with-colons |
  awk -F: '$1=="sub"{s=1;next} $1=="fpr" && s{print $10; s=0}')
SUB_A=${SUBS[0]}; SUB_B=${SUBS[1]}
# Erst jetzt, denn gpg signiert nicht mit einem Schluessel, der aus Sicht der
# gefaelschten Zeit noch nicht existiert. Der Test hat hier eine Sekunde
# Unterschied gefunden, als die Epoche vor der Erzeugung genommen wurde.
EPOCH=$(date +%s)

check "Primaer ist certify-only" \
  "$(gpg --list-keys --with-colons | awk -F: '$1=="pub"{print $12; exit}')" "cSC"
check "zwei Signing-Subkeys" "${#SUBS[@]}" "2"

# Export nur der geheimen Subkeys. Das Ausrufezeichen pinnt auf einen.
"${G[@]}" --export-secret-subkeys --armor "${SUB_A}!" > "$work/bundle-a.asc"
"${G[@]}" --export-secret-subkeys --armor "${SUB_B}!" > "$work/bundle-b.asc"
"${G[@]}" --export-secret-keys --armor "$PRIMARY" > "$work/bundle-full.asc"
# Beide geheimen Subkeys in einem Bundle. Ohne diese Fixture ist das Pinning
# per Ausrufezeichen nicht pruefbar: bei nur einem Subkey kann gpg auch
# ungepinnt nichts falsch auswaehlen, und der Export enthaelt ohnehin nur einen.
"${G[@]}" --export-secret-subkeys --armor "$PRIMARY" > "$work/bundle-both.asc"

manifest() {  # $1 = Ziel, $2 = Primaer, $3 = Subkey
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

render() {  # $1 = Ausgabeverzeichnis
  local pool="$work/pool"
  if [ ! -d "$pool" ]; then
    mkdir -p "$pool"
    python3 "$root/tests/make_deb.py" --out "$pool/demo_1.0.0_amd64.deb" \
      --package demo --version 1.0.0 --architecture amd64
  fi
  manifest "$work/m.toml" "$PRIMARY" "$SUB_A"
  AR_RENDER_LOCAL=1 "$root/scripts/render-archive.sh" --manifest "$work/m.toml" \
    --project demo --pool-dir "$pool" --output-dir "$1" --metadata-epoch "$EPOCH" >/dev/null
}

sign() {  # $1 = Archivverzeichnis, $2 = Manifest, $3 = Bundle
  "$root/scripts/sign-archive.sh" --manifest "$2" --archive-dir "$1" \
    --private-key "$3" --passphrase-file "$work/pass" --metadata-epoch "$EPOCH" 2>&1
}

printf '\n== T1  Signieren mit dem Subkey der Domain ==\n'
A="$work/a"; render "$A"
manifest "$work/m.toml" "$PRIMARY" "$SUB_A"
out=$(sign "$A" "$work/m.toml" "$work/bundle-a.asc")
if [ $? -ne 0 ]; then bad "T1 Signatur" "$out"; else
  ok "T1 Signatur laeuft"
  check "T1 InRelease vorhanden"   "$([ -f "$A/dists/rolling/InRelease" ] && echo ja || echo nein)" "ja"
  check "T1 Release.gpg vorhanden" "$([ -f "$A/dists/rolling/Release.gpg" ] && echo ja || echo nein)" "ja"
  check "T1 Keyring dearmored"     "$([ -f "$A/example-archive-keyring.gpg" ] && echo ja || echo nein)" "ja"
  check "T1 Keyring armored"       "$([ -f "$A/example-archive-keyring.asc" ] && echo ja || echo nein)" "ja"
  check "T1 Keyring hat genau einen Subkey" \
    "$(gpg --no-options --batch --with-colons --show-keys "$A/example-archive-keyring.gpg" | grep -c '^sub')" "1"
  # Es muss der richtige Subkey sein, nicht irgendeiner.
  check "T1 und zwar Subkey A" \
    "$(gpg --no-options --batch --with-colons --show-keys "$A/example-archive-keyring.gpg" |
       awk -F: '$1=="sub"{s=1;next} $1=="fpr" && s{print toupper($10); exit}')" "${SUB_A^^}"
  signer=$(gpgv --keyring "$A/example-archive-keyring.gpg" --status-fd 1 \
             "$A/dists/rolling/InRelease" 2>/dev/null | awk '/VALIDSIG/{print $3}')
  check "T1 signiert hat Subkey A" "${signer^^}" "${SUB_A^^}"
fi

printf '\n== T2  Determinismus ==\n'
# Nur sinnvoll, wenn T1 wirklich signiert hat: sonst vergleicht der Test zwei
# unsignierte Baeume und ist gruen, ohne etwas zu pruefen.
if [ -f "$A/dists/rolling/InRelease" ]; then
  B="$work/b"; render "$B"
  if sign "$B" "$work/m.toml" "$work/bundle-a.asc" >/dev/null; then
    if diff -r "$A" "$B" >/dev/null 2>&1; then ok "T2 zwei Laeufe byteidentisch"
    else bad "T2 zwei Laeufe byteidentisch" "$(diff -rq "$A" "$B" 2>&1 | head -3)"; fi
  else
    bad "T2 zwei Laeufe byteidentisch" "zweiter Signaturlauf scheiterte"
  fi
else
  bad "T2 zwei Laeufe byteidentisch" "uebersprungen, T1 hat nicht signiert"
fi

printf '\n== T3  Ablehnungen ==\n'
reject() {  # $1 = Name, $2 = Textfragment, $3 = Manifest, $4 = Bundle
  local d="$work/r.$RANDOM"; render "$d"
  local msg; msg=$(sign "$d" "$3" "$4")
  if printf '%s' "$msg" | grep -qF "$2"; then ok "T3 $1"
  else bad "T3 $1" "erwartete [$2], erhielt: $(printf '%s' "$msg" | head -1)"; fi
}
manifest "$work/m-wrong.toml" "$PRIMARY" "$SUB_B"
reject "fremder Subkey wird abgelehnt" "not in the bundle" "$work/m-wrong.toml" "$work/bundle-a.asc"
reject "Bundle mit geheimem Primaer wird abgelehnt" "primary secret key is present" "$work/m.toml" "$work/bundle-full.asc"
manifest "$work/m-tbd.toml" "$PRIMARY" "$SUB_A"
sed -i.bak 's/^signing_subkey = .*/signing_subkey = "TBD"/' "$work/m-tbd.toml"
reject "TBD im Manifest wird abgelehnt" "usable signing values" "$work/m-tbd.toml" "$work/bundle-a.asc"
manifest "$work/m-badprim.toml" "${SUB_B}" "$SUB_A"
reject "falscher Primaer wird abgelehnt" "manifest names" "$work/m-badprim.toml" "$work/bundle-a.asc"

printf '\n== T4  Pinning bei zwei Subkeys im Bundle ==\n'
# Das eigentliche Kernstueck. Liegen beide Domain-Subkeys im Bundle, muss
# trotzdem genau der aus dem Manifest signieren, und der Keyring darf nur
# diesen einen enthalten.
# Ein Geheimschluessel-Export fuehrt Subkeys als ssb, nicht als sub.
check "T4 Bundle enthaelt zwei geheime Subkeys" \
  "$(gpg --no-options --batch --with-colons --show-keys "$work/bundle-both.asc" | grep -c '^ssb')" "2"
D="$work/d"; render "$D"
manifest "$work/m.toml" "$PRIMARY" "$SUB_A"
out=$(sign "$D" "$work/m.toml" "$work/bundle-both.asc")
if [ $? -ne 0 ]; then bad "T4 Signatur mit Zwei-Subkey-Bundle" "$out"; else
  ok "T4 Signatur laeuft"
  check "T4 Keyring hat genau einen Subkey" \
    "$(gpg --no-options --batch --with-colons --show-keys "$D/example-archive-keyring.gpg" | grep -c '^sub')" "1"
  check "T4 und zwar Subkey A" \
    "$(gpg --no-options --batch --with-colons --show-keys "$D/example-archive-keyring.gpg" |
       awk -F: '$1=="sub"{s=1;next} $1=="fpr" && s{print toupper($10); exit}')" "${SUB_A^^}"
  signer=$(gpgv --keyring "$D/example-archive-keyring.gpg" --status-fd 1 \
             "$D/dists/rolling/InRelease" 2>/dev/null | awk '/VALIDSIG/{print $3}')
  check "T4 signiert hat Subkey A, nicht B" "${signer^^}" "${SUB_A^^}"
  # Der armored Keyring wird genauso ausgeliefert. Ohne eigene Zusicherung
  # bliebe ein ungepinnter Export dort unbemerkt.
  check "T4 armored Keyring hat genau einen Subkey" \
    "$(gpg --no-options --batch --with-colons --show-keys "$D/example-archive-keyring.asc" | grep -c '^sub')" "1"
  check "T4 armored Keyring fuehrt Subkey A" \
    "$(gpg --no-options --batch --with-colons --show-keys "$D/example-archive-keyring.asc" |
       awk -F: '$1=="sub"{s=1;next} $1=="fpr" && s{print toupper($10); exit}')" "${SUB_A^^}"
  # Beide Fassungen muessen dasselbe Zertifikat sein.
  check "T4 armored und dearmored deckungsgleich" \
    "$(gpg --no-options --batch --with-colons --show-keys "$D/example-archive-keyring.asc" | grep '^fpr' | sort | md5)" \
    "$(gpg --no-options --batch --with-colons --show-keys "$D/example-archive-keyring.gpg" | grep '^fpr' | sort | md5)"
  # Gegenprobe: derselbe Baum, aber Manifest auf B. Dann muss B signieren.
  E="$work/e"; render "$E"
  manifest "$work/m-b.toml" "$PRIMARY" "$SUB_B"
  if sign "$E" "$work/m-b.toml" "$work/bundle-both.asc" >/dev/null; then
    signer=$(gpgv --keyring "$E/example-archive-keyring.gpg" --status-fd 1 \
               "$E/dists/rolling/InRelease" 2>/dev/null | awk '/VALIDSIG/{print $3}')
    check "T4 Manifest auf B laesst B signieren" "${signer^^}" "${SUB_B^^}"
  else
    bad "T4 Manifest auf B laesst B signieren" "Signaturlauf scheiterte"
  fi
fi

printf '\n== T5  Epoche vor der Schluesselerzeugung ==\n'
F="$work/f"; render "$F"
msg=$("$root/scripts/sign-archive.sh" --manifest "$work/m.toml" --archive-dir "$F" \
        --private-key "$work/bundle-a.asc" --passphrase-file "$work/pass" \
        --metadata-epoch 1700000000 2>&1)
if printf '%s' "$msg" | grep -qF 'precedes the subkey creation'; then
  ok "T5 zu fruehe Epoche wird benannt abgelehnt"
else
  bad "T5 zu fruehe Epoche wird benannt abgelehnt" "$(printf '%s' "$msg" | head -1)"
fi

printf '\n  bestanden %d, fehlgeschlagen %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
