#!/usr/bin/env bash
# Vertragstests fuer den Renderer. Kein Netz, kein Schluessel, kein dpkg.
set -uo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)
render="$root/scripts/render_archive.py"
validate_time="$root/scripts/release_time.py"
mkdeb="$root/tests/make_deb.py"
work=$(mktemp -d); trap 'rm -rf -- "$work"' EXIT
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "erwartet [$3], erhalten [$2]"; fi; }

manifest() {  # $1 = Zieldatei, $2... = zusaetzliche Zeilen
  local out=$1; shift
  cat > "$out" <<TOML
[domain]
host = "deb.example.invalid"
base_url = "https://deb.example.invalid"
origin = "example"
keyring_package = "example-archive-keyring"
keyring_file = "/usr/share/keyrings/example-archive-keyring.pgp"

[signing]
primary_fingerprint = "TBD"
signing_subkey = "TBD"

[publication]
r2_bucket = "TBD"
r2_account_id = "0"

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
source_repo = "example/demo"
packages = ["demo", "demo-extras"]
TOML
  for line in "$@"; do printf '%s\n' "$line" >> "$out"; done
}

deb() {  # $1 = Verzeichnis, danach make_deb-Argumente
  local dir=$1; shift
  python3 "$mkdeb" --out "$dir/$(python3 - "$@" <<'PY'
import sys
a=dict(zip(sys.argv[1::2], sys.argv[2::2]))
print(f"{a['--package']}_{a['--version']}_{a['--architecture']}.deb")
PY
)" "$@"
}

run() { python3 "$render" "$@" 2>&1; }

# Ein Renderer, der nach teilweiser Ausgabe abbricht, darf nicht in die
# folgenden greps laufen: die Meldungen waeren dann irrefuehrend statt klar.
must_run() {  # $1 = Testname, danach die Renderer-Argumente
  local name=$1; shift
  local out
  if out=$(run "$@"); then return 0; fi
  bad "$name" "Renderer brach ab: $(printf '%s' "$out" | head -1)"
  return 1
}

EPOCH=1700000000

wrapper="$root/scripts/render-archive.sh"
check "Wrapper erzeugt sein Staging atomar mit mktemp" \
  "$(grep -c 'staging=$(mktemp -d ' "$wrapper")" "1"
check "Wrapper verwendet keinen vorhersagbaren PID-Pfad" \
  "$(grep -Fc '.render.$$' "$wrapper")" "0"

# ---------------------------------------------------------------- T1
t="T1  mehrere Pakete, mehrere Versionen, mehrere Architekturen"
m="$work/t1.toml"; manifest "$m"
p="$work/t1pool"; mkdir -p "$p"
for v in 1.0.0 1.1.0 2.0.0; do
  for a in amd64 arm64; do
    deb "$p" --package demo --version "$v" --architecture "$a"
    deb "$p" --package demo-extras --version "$v" --architecture "$a"
  done
done
o="$work/t1out"
out=$(run --manifest "$m" --project demo --pool-dir "$p" --output-dir "$o" --publication-epoch $EPOCH)
if [ $? -ne 0 ]; then bad "$t" "$out"; else
  check "$t: Poolobjekte"      "$(find "$o/pool" -name '*.deb' | wc -l | tr -d ' ')" "12"
  check "$t: Poolpfad"         "$([ -f "$o/pool/main/d/demo/demo_2.0.0_amd64.deb" ] && echo ja || echo nein)" "ja"
  check "$t: Stanzas amd64"    "$(grep -c '^Package:' "$o/dists/rolling/main/binary-amd64/Packages")" "6"
  check "$t: Stanzas arm64"    "$(grep -c '^Package:' "$o/dists/rolling/main/binary-arm64/Packages")" "6"
  check "$t: keine Fremdarch"  "$(grep -c 'arm64' "$o/dists/rolling/main/binary-amd64/Packages")" "0"
fi

# ---------------------------------------------------------------- T2
t="T2  by-hash liegt fuer jeden in Release genannten Hash vor"
rel="$o/dists/rolling/Release"
algs=$(grep -E '^(SHA256|SHA512|MD5Sum|SHA1):$' "$rel" | tr -d ':' | sort | tr '\n' ' ')
check "$t: Hashfelder"        "$(echo $algs)" "SHA256 SHA512"
b="$o/dists/rolling/main/binary-amd64"
for alg in SHA256 SHA512; do
  low=$(echo "$alg" | tr 'A-Z' 'a-z')
  miss=0
  for f in Packages Packages.gz; do
    h=$(python3 -c "import hashlib,sys;print(hashlib.new('$low',open(sys.argv[1],'rb').read()).hexdigest())" "$b/$f")
    [ -f "$b/by-hash/$alg/$h" ] || miss=$((miss+1))
  done
  check "$t: $alg vollstaendig" "$miss" "0"
done

# ---------------------------------------------------------------- T3
t="T3  Release ist vollstaendig und deterministisch"
check "$t: Acquire-By-Hash"  "$(grep -c '^Acquire-By-Hash: yes$' "$rel")" "1"
check "$t: Suite"            "$(grep -c '^Suite: rolling$' "$rel")" "1"
check "$t: Valid-Until"      "$(grep -c '^Valid-Until: ' "$rel")" "1"
check "$t: kein by-hash drin" "$(grep -c 'by-hash' "$rel")" "0"
if python3 "$validate_time" --manifest "$m" --release "$rel" \
    --publication-epoch "$EPOCH" --now-epoch "$EPOCH" --max-age-seconds 0; then
  ok "$t: Date und Valid-Until exakt aus Publikations-Epoche"
else
  bad "$t: Date und Valid-Until exakt aus Publikations-Epoche"
fi
o2="$work/t1out2"
must_run "$t" --manifest "$m" --project demo --pool-dir "$p" \
  --output-dir "$o2" --publication-epoch $EPOCH || true
if diff -r "$o" "$o2" >/dev/null 2>&1; then ok "$t: zwei Laeufe byteidentisch"
else bad "$t: zwei Laeufe byteidentisch" "$(diff -rq "$o" "$o2" | head -3)"; fi

later_epoch=$((EPOCH + 86400))
o3="$work/t1out3"
must_run "$t" --manifest "$m" --project demo --pool-dir "$p" \
  --output-dir "$o3" --publication-epoch "$later_epoch" || true
if diff -r "$o/pool" "$o3/pool" >/dev/null 2>&1; then
  ok "$t: neue Epoche laesst Pool unveraendert"
else
  bad "$t: neue Epoche laesst Pool unveraendert"
fi
if diff -r "$o/dists/rolling/main" "$o3/dists/rolling/main" >/dev/null 2>&1; then
  ok "$t: neue Epoche laesst Indexe und by-hash unveraendert"
else
  bad "$t: neue Epoche laesst Indexe und by-hash unveraendert"
fi
if cmp -s "$rel" "$o3/dists/rolling/Release"; then
  bad "$t: neue Epoche aendert Release"
else
  ok "$t: neue Epoche aendert Release"
fi
if diff <(sed '/^Date: /d; /^Valid-Until: /d' "$rel") \
        <(sed '/^Date: /d; /^Valid-Until: /d' "$o3/dists/rolling/Release") \
        >/dev/null 2>&1; then
  ok "$t: in Release aendern sich nur die Zeitfelder"
else
  bad "$t: in Release aendern sich nur die Zeitfelder"
fi
if python3 "$validate_time" --manifest "$m" \
    --release "$o3/dists/rolling/Release" --publication-epoch "$later_epoch" \
    --now-epoch "$later_epoch" --max-age-seconds 0; then
  ok "$t: spaetere Epoche und 180-Tage-Frist sind exakt"
else
  bad "$t: spaetere Epoche und 180-Tage-Frist sind exakt"
fi
expired_now=$((EPOCH + 180 * 86400))
msg=$(python3 "$validate_time" --manifest "$m" --release "$rel" \
        --publication-epoch "$EPOCH" --now-epoch "$expired_now" 2>&1)
if printf '%s' "$msg" | grep -qF 'Release expired at'; then
  ok "$t: abgelaufenes Valid-Until wird kalendarisch abgelehnt"
else
  bad "$t: abgelaufenes Valid-Until wird kalendarisch abgelehnt" \
    "$(printf '%s' "$msg" | head -1)"
fi

# Der absolute Ausgabepfad darf fuer die Release-Auswahl keine Bedeutung
# haben. Ein Elternverzeichnis namens by-hash darf keine Indexe verschlucken.
byhash_parent="$work/by-hash"; mkdir -p "$byhash_parent"
byhash_out="$byhash_parent/archive"
if must_run "$t" --manifest "$m" --project demo --pool-dir "$p" \
    --output-dir "$byhash_out" --publication-epoch $EPOCH; then
  check "$t: by-hash im absoluten Pfad entfernt keine Indexe" \
    "$(grep -c 'main/binary-amd64/Packages.gz$' "$byhash_out/dists/rolling/Release")" "2"
fi

# ---------------------------------------------------------------- T4
t="T4  Architecture: all landet in jedem Binaerindex"
m4="$work/t4.toml"; manifest "$m4"
p4="$work/t4pool"; mkdir -p "$p4"
deb "$p4" --package demo --version 1.0.0 --architecture amd64
deb "$p4" --package demo --version 1.0.0 --architecture arm64
deb "$p4" --package demo-extras --version 1.0.0 --architecture all
o4="$work/t4out"
if must_run "$t" --manifest "$m4" --project demo --pool-dir "$p4" \
    --output-dir "$o4" --publication-epoch $EPOCH; then
for a in amd64 arm64; do
  check "$t: $a enthaelt all" \
    "$(grep -c '^Architecture: all$' "$o4/dists/rolling/main/binary-$a/Packages")" "1"
  check "$t: $a Stanzas" \
    "$(grep -c '^Package:' "$o4/dists/rolling/main/binary-$a/Packages")" "2"
done
fi

# ---------------------------------------------------------------- T5
t="T5  leerer Index fuer eine bediente Architektur ohne Paket"
m5="$work/t5.toml"; manifest "$m5"
p5="$work/t5pool"; mkdir -p "$p5"
deb "$p5" --package demo --version 1.0.0 --architecture amd64
o5="$work/t5out"
must_run "$t" --manifest "$m5" --project demo --pool-dir "$p5" \
  --output-dir "$o5" --publication-epoch $EPOCH || true
check "$t: arm64-Index existiert" "$([ -f "$o5/dists/rolling/main/binary-arm64/Packages" ] && echo ja || echo nein)" "ja"
check "$t: arm64-Index leer"      "$(wc -c < "$o5/dists/rolling/main/binary-arm64/Packages" | tr -d ' ')" "0"
# Jeder Index steht einmal je Hashabschnitt, bei SHA256 und SHA512 also zweimal.
check "$t: arm64 in Release"      "$(grep -c 'binary-arm64/Packages$' "$o5/dists/rolling/Release")" "2"

# ---------------------------------------------------------------- T6  Ablehnungen
reject() {  # $1 = Name, $2 = erwartetes Textfragment, danach Aufbau via Callback
  local name=$1 want=$2; shift 2
  local msg; msg=$("$@" 2>&1)
  if printf '%s' "$msg" | grep -qF "$want"; then ok "T6  $name"
  else bad "T6  $name" "erwartete Meldung mit [$want], erhalten: $(printf '%s' "$msg" | head -1)"; fi
}

mk_unknown_pkg() {
  local d=$work/r1; mkdir -p "$d/pool"; manifest "$d/m.toml"
  deb "$d/pool" --package fremdpaket --version 1.0.0 --architecture amd64
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "unbekannter Paketname wird abgelehnt" "does not list" mk_unknown_pkg

mk_unknown_arch() {
  local d=$work/r2; mkdir -p "$d/pool"; manifest "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture riscv64
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "unbediente Architektur wird abgelehnt" "does not serve" mk_unknown_arch

mk_duplicate() {
  local d=$work/r3; mkdir -p "$d/pool"; manifest "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture amd64
  cp "$d/pool/demo_1.0.0_amd64.deb" "$d/pool/kopie.deb"
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "doppelte Identitaet wird abgelehnt" "both provide" mk_duplicate

mk_unknown_project() {
  local d=$work/r4; mkdir -p "$d/pool"; manifest "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture amd64
  run --manifest "$d/m.toml" --project gibtesnicht --pool-dir "$d/pool" --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "unbekanntes Projekt wird abgelehnt" "not declared exactly once" mk_unknown_project

mk_byhash_off() {
  local d=$work/r5; mkdir -p "$d/pool"; manifest "$d/m.toml"
  sed -i.bak 's/acquire_by_hash = true/acquire_by_hash = false/' "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture amd64
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "abgeschaltetes by-hash wird abgelehnt" "acquire_by_hash must stay enabled" mk_byhash_off

mk_existing_out() {
  local d=$work/r6; mkdir -p "$d/pool" "$d/out"; manifest "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture amd64
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "vorhandenes Ausgabeverzeichnis wird abgelehnt" "must be a new path" mk_existing_out

mk_unsafe_version() {
  local d=$work/r7; mkdir -p "$d/pool"; manifest "$d/m.toml"
  python3 "$mkdeb" --out "$d/pool/evil.deb" --package demo \
    --version '1.0/../../../../../../escaped/y' --architecture amd64
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" \
    --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "Pfad-Traversal in Version wird abgelehnt" "unsafe version" mk_unsafe_version

mk_unsafe_source() {
  local d=$work/r8; mkdir -p "$d/pool"; manifest "$d/m.toml"
  python3 "$mkdeb" --out "$d/pool/evil.deb" --package demo --version 1.0.0 \
    --architecture amd64 --source '../../../../escaped/source'
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" \
    --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "Pfad-Traversal in Source wird abgelehnt" "unsafe source name" mk_unsafe_source

mk_computed_field() {
  local field=$1 d="$work/computed.$1"; mkdir -p "$d/pool"; manifest "$d/m.toml"
  python3 "$mkdeb" --out "$d/pool/evil.deb" --package demo --version 1.0.0 \
    --architecture amd64 --extra "$field=forged"
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" \
    --output-dir "$d/out" --publication-epoch $EPOCH
}
for field in Filename Size SHA256 SHA512; do
  reject "berechnetes Control-Feld $field wird abgelehnt" \
    "archive-computed control fields: $field" mk_computed_field "$field"
done

mk_all_native_conflict() {
  local d=$work/r9; mkdir -p "$d/pool"; manifest "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture all
  deb "$d/pool" --package demo --version 1.0.0 --architecture amd64
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" \
    --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "Architecture all und nativ derselben Version werden abgelehnt" \
  "provided both as Architecture: all and as a native package" mk_all_native_conflict

mk_damaged() {
  local fixture=$1 d="$work/damaged.$1"; mkdir -p "$d/pool"; manifest "$d/m.toml"
  python3 "$mkdeb" --out "$d/pool/damaged.deb" --package demo --version 1.0.0 \
    --architecture amd64 --fixture "$fixture"
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" \
    --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "falsche ar-Magie wird abgelehnt" "no ar archive signature" \
  mk_damaged bad-ar-magic
reject "abgeschnittener ar-Header wird abgelehnt" "truncated ar member header" \
  mk_damaged truncated-ar-header
reject "doppeltes ar-Mitglied wird abgelehnt" "repeats or omits an ar member name" \
  mk_damaged duplicate-ar-member
reject "falsches ar-Padding wird abgelehnt" "malformed ar member padding" \
  mk_damaged bad-ar-padding
reject "beschaedigte Kompression wird abgelehnt" "cannot decompress control metadata" \
  mk_damaged corrupt-control-compression
reject "beschaedigtes Control-Tar wird abgelehnt" "cannot parse control archive" \
  mk_damaged corrupt-control-tar
reject "fehlende Control-Datei wird abgelehnt" "exactly one regular control file" \
  mk_damaged missing-control
reject "doppelte Control-Datei wird abgelehnt" "exactly one regular control file" \
  mk_damaged duplicate-control
reject "Control-Symlink wird abgelehnt" "not a bounded regular file" \
  mk_damaged symlink-control
reject "Control ohne Abschlusszeile wird abgelehnt" "unsafe Debian control metadata" \
  mk_damaged control-no-newline
reject "Control mit NUL wird abgelehnt" "unsafe Debian control metadata" \
  mk_damaged control-nul

# ---------------------------------------------------------------- T7
# Manifestwerte werden geprueft, nicht umgewandelt. `bool("false")` ist True
# und `int(True)` ist 1; eine Umwandlung machte aus einem Tippfehler ein
# stillschweigend falsches Archiv.
t="T7  Manifesttypen werden geprueft statt umgewandelt"
t7() {  # $1 = sed-Ausdruck auf das Manifest, $2 = erwartetes Textfragment
  local d="$work/t7.$RANDOM"; mkdir -p "$d/pool"
  manifest "$d/m.toml"
  sed -i.bak "$1" "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture amd64
  local msg
  msg=$(run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" \
          --output-dir "$d/out" --publication-epoch $EPOCH 2>&1)
  if printf '%s' "$msg" | grep -qF "$2"; then ok "$t: $3"
  else bad "$t: $3" "erwartete [$2], erhielt: $(printf '%s' "$msg" | head -1)"; fi
}
t7 's/acquire_by_hash = true/acquire_by_hash = "false"/' \
   'acquire_by_hash must be bool, not str' 'String statt bool'
t7 's/valid_until_days = 180/valid_until_days = true/' \
   'valid_until_days must be int, not bool' 'bool statt int'
t7 's/valid_until_days = 180/valid_until_days = "180"/' \
   'valid_until_days must be int, not str' 'String statt int'
t7 's/valid_until_days = 180/valid_until_days = 1/' \
   'valid_until_days must cover at least a week' 'zu kurze Gueltigkeitsfrist'
t7 's/components = \["main"\]/components = [1]/' \
   'components must hold only strings' 'Zahl in einer Stringliste'

# ---------------------------------------------------------------- T8
# Ein Zeilenumbruch in einem Feld, das in die Release-Datei geschrieben wird,
# haengt ihr eine beliebige weitere Zeile an.
t="T8  Release-Felder duerfen keine Steuerzeichen enthalten"
t7 's|origin = "example"|origin = "example\\nSuite: evil"|' \
   'origin must be one printable line' 'Zeilenumbruch in origin'
t7 's|origin = "example"|origin = "exa\\tmple"|' \
   'origin must be one printable line' 'Tabulator in origin'

unsafe_project=$'demo\nLabel: evil'
msg=$(run --manifest "$m" --project "$unsafe_project" --pool-dir "$p" \
        --output-dir "$work/unsafe-project" --publication-epoch $EPOCH 2>&1)
if printf '%s' "$msg" | grep -qF 'project name must be one safe printable field'; then
  ok "$t: Zeilenumbruch in Projektname"
else
  bad "$t: Zeilenumbruch in Projektname" "$(printf '%s' "$msg" | head -1)"
fi

prefix_manifest="$work/unsafe-prefix.toml"; manifest "$prefix_manifest"
sed -i.bak 's|prefix = "/demo"|prefix = "/demo\\nValid-Until: Thu, 01 Jan 2099 00:00:00 +0000"|' \
  "$prefix_manifest"
msg=$(run --manifest "$prefix_manifest" --project demo --pool-dir "$p" \
        --output-dir "$work/unsafe-prefix" --publication-epoch $EPOCH 2>&1)
if printf '%s' "$msg" | grep -qF 'unsafe prefix'; then
  ok "$t: Zeilenumbruch in Praefix"
else
  bad "$t: Zeilenumbruch in Praefix" "$(printf '%s' "$msg" | head -1)"
fi

printf '\n  bestanden %d, fehlgeschlagen %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
