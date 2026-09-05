#!/usr/bin/env bash
# Prueft ein veroeffentlichtes Archiv gegen die oeffentliche URL.
#
#   verify-publication.sh --manifest domains/<host>/manifest.toml \
#                         --project <name> --archive-dir <lokale wurzel> \
#                         --publication-epoch <epoch> \
#                         [--base-url <uebersteuerung>]
#
# Geprueft wird, was ein Client tatsaechlich bekommt, nicht was hochgeladen
# wurde. Ohne Zugangsdaten, rein lesend.
#
#   1  Keyring laden
#   2  InRelease laden und mit gpgv gegen diesen Keyring pruefen
#   3  InRelease byteweise gegen die lokale Fassung vergleichen
#   4  je Architektur Packages.gz laden und gegen die Summe aus InRelease pruefen
#   5  denselben Index unter seinem by-hash-Pfad laden und vergleichen
#   6  den ersten Filename-Eintrag aufloesen, das Paket laden und byteweise
#      gegen die lokale Datei vergleichen
#
# --base-url dient den Tests, die den Baum lokal ausliefern.
set -euo pipefail

fail() { printf '::error::AR160 %s\n' "$*" >&2; exit 1; }

# Ein `shift 2` ohne Wert bricht mit bashs eigener Meldung ab, und bei
# `set -e` sogar lautlos: Exitcode 1, keine Ausgabe auf stdout oder stderr. In
# einem Workflow bliebe nur "Process completed with exit code 1" stehen.
opt_value() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"; }
step() { printf '  %s\n' "$*"; }

manifest=''; project=''; archive_dir=''; publication_epoch=''; base_override=''
while (($#)); do
  case "$1" in
    --manifest)    opt_value "$@"; manifest=$2; shift 2 ;;
    --project)     opt_value "$@"; project=$2; shift 2 ;;
    --archive-dir) opt_value "$@"; archive_dir=$2; shift 2 ;;
    --publication-epoch) opt_value "$@"; publication_epoch=$2; shift 2 ;;
    --base-url)    opt_value "$@"; base_override=$2; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
for name in manifest project archive_dir publication_epoch; do
  [[ -n "${!name}" ]] || fail "--${name//_/-} is required"
done
for command in curl gpg gpgv gzip python3 shasum; do
  command -v "$command" >/dev/null || fail "required command is missing: $command"
done
[[ -f "$manifest"    && ! -L "$manifest"    ]] || fail 'manifest must be a regular file'
[[ -d "$archive_dir" && ! -L "$archive_dir" ]] || fail 'archive-dir must be a real directory'
[[ "$publication_epoch" =~ ^[1-9][0-9]*$ ]] \
  || fail 'publication-epoch must be a positive integer'
archive_dir=$(unset CDPATH; cd -- "$archive_dir" && pwd -P)

script_root=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
time_validator="$script_root/release_time.py"
[[ -f "$time_validator" && ! -L "$time_validator" ]] \
  || fail 'Release time validator is missing or unsafe'

read -r base_url prefix suite keyring_package architectures < <(
  MANIFEST="$manifest" PROJECT="$project" python3 - <<'PY'
import os, tomllib
with open(os.environ["MANIFEST"], "rb") as handle:
    data = tomllib.load(handle)
project = os.environ["PROJECT"]
matches = [p for p in data.get("projects", []) if isinstance(p, dict) and p.get("name") == project]
if len(matches) != 1:
    raise SystemExit(f"project {project!r} is not declared exactly once")
print(data["domain"]["base_url"],
      matches[0]["prefix"].lstrip("/"),
      data["release"]["suite"],
      data["domain"]["keyring_package"],
      ",".join(data["release"]["architectures"]))
PY
) || fail 'cannot read the publication target from the manifest'
[[ -n "$base_override" ]] && base_url="$base_override"
base_url=${base_url%/}

work=$(mktemp -d /tmp/apt-archive-verify.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

# Begrenzt laden: ein feindlicher Ursprung soll den Pruefer nicht fuellen.
get() {  # $1 = Pfad relativ zur Basis, $2 = Ziel, $3 = Groessengrenze in Bytes
  curl -sSfL --proto '=https,http' --max-time 120 --max-filesize "$3" \
    -o "$2" "${base_url}/$1" || fail "cannot fetch ${base_url}/$1"
}

step "1  Keyring"
get "${keyring_package}.pgp" "$work/keyring.pgp" 1048576
if ! subkeys=$(gpg --no-options --batch --with-colons \
               --show-keys "$work/keyring.pgp" 2>/dev/null |
                 awk -F: '$1 == "sub" { count += 1 } END { print count + 0 }'); then
  fail 'cannot inspect the published keyring'
fi
[[ "$subkeys" == 1 ]] || fail "the published keyring carries $subkeys subkeys, expected exactly 1"
step "    genau ein Subkey, wie vorgesehen"

step "2  InRelease und Signatur"
inrelease="${prefix}/dists/${suite}/InRelease"
get "$inrelease" "$work/InRelease" 4194304
status=$(gpgv --keyring "$work/keyring.pgp" --status-fd 1 \
           "$work/InRelease" 2>/dev/null) \
  || fail 'gpgv rejected the published InRelease against the published keyring'
signer=$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" {print $3}')
signature_epoch=$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" {print $5}')
[[ "$signature_epoch" == "$publication_epoch" ]] \
  || fail "published signature time $signature_epoch does not equal publication epoch $publication_epoch"
# gpgv 2.5 verifiziert eine Clearsignatur, schreibt deren Klartext mit
# --output aber nicht portabel aus. Deshalb getrennt mit demselben isolierten
# Keyring extrahieren; die Vertrauensentscheidung oben bleibt bei gpgv.
install -d -m 0700 "$work/gnupg"
gpg --no-options --batch --homedir "$work/gnupg" --no-default-keyring \
  --keyring "$work/keyring.pgp" --output "$work/Release" \
  --decrypt "$work/InRelease" >/dev/null 2>&1 \
  || fail 'cannot extract the signed Release from the published InRelease'
python3 "$time_validator" --manifest "$manifest" --release "$work/Release" \
  --publication-epoch "$publication_epoch" \
  || fail 'published Release time validation failed'
step "    gpgv akzeptiert, signiert von ${signer}, Epoche ${signature_epoch}"

step "3  Byteweiser Abgleich mit dem lokalen Baum"
local_inrelease="$archive_dir/dists/${suite}/InRelease"
[[ -f "$local_inrelease" ]] || fail "the local InRelease is missing: $local_inrelease"
cmp -s "$work/InRelease" "$local_inrelease" \
  || fail 'the published InRelease differs from the local one'
step "    identisch"

step "4  Indexe gegen die Summen aus InRelease"
IFS=',' read -r -a arches <<< "$architectures"
: > "$work/filenames"
for arch in "${arches[@]}"; do
  rel="main/binary-${arch}/Packages.gz"
  get "${prefix}/dists/${suite}/${rel}" "$work/Packages.gz" 16777216
  want=$(INRELEASE="$work/InRelease" REL="$rel" python3 - <<'PY'
import os, re
text = open(os.environ["INRELEASE"], encoding="utf-8", errors="strict").read()
target = os.environ["REL"]
section = None
for line in text.splitlines():
    if re.fullmatch(r"(MD5Sum|SHA1|SHA256|SHA512):", line.strip()):
        section = line.strip().rstrip(":")
        continue
    if section == "SHA256" and line.startswith(" "):
        parts = line.split()
        if len(parts) == 3 and parts[2] == target:
            print(parts[0])
            break
PY
)
  [[ -n "$want" ]] || fail "InRelease names no SHA256 for $rel"
  have=$(shasum -a 256 "$work/Packages.gz" | cut -d' ' -f1)
  [[ "$want" == "$have" ]] || fail "$rel does not match its SHA256 from InRelease"
  step "    ${arch}: Packages.gz stimmt"

  # Genau der Pfad, den apt tatsaechlich anfragt: der staerkste Hash aus
  # Release. Am 1. September 2026 gemessen, siehe apt-archive.md.
  want512=$(INRELEASE="$work/InRelease" REL="$rel" python3 - <<'PY'
import os, re
text = open(os.environ["INRELEASE"], encoding="utf-8", errors="strict").read()
target, section = os.environ["REL"], None
for line in text.splitlines():
    if re.fullmatch(r"(MD5Sum|SHA1|SHA256|SHA512):", line.strip()):
        section = line.strip().rstrip(":")
        continue
    if section == "SHA512" and line.startswith(" "):
        parts = line.split()
        if len(parts) == 3 and parts[2] == target:
            print(parts[0])
            break
PY
)
  [[ -n "$want512" ]] || fail "InRelease names no SHA512 for $rel"
  get "${prefix}/dists/${suite}/main/binary-${arch}/by-hash/SHA512/${want512}" \
      "$work/by-hash" 16777216
  cmp -s "$work/by-hash" "$work/Packages.gz" \
    || fail "the by-hash copy of $rel differs from the plain path"
  step "    ${arch}: by-hash/SHA512 identisch"

  # Jeder Filename-Eintrag, nicht nur der erste. awk liest absichtlich bis EOF:
  # ein frueher `exit` schliesst die Pipe, laesst gzip bei grossen Indexen mit
  # SIGPIPE 141 sterben und beendet unter pipefail die gesamte Nachkontrolle
  # ohne unsere Fehlermeldung.
  gzip -dc "$work/Packages.gz" |
    awk '$1 == "Filename:" { print $2 }' >> "$work/filenames" \
    || fail "cannot inspect $rel for package filenames"
done

step "5  Jedes veroeffentlichte Paket byteweise"
# Ein Paket, das in mehreren Architektur-Indexen steht, etwa mit
# Architecture: all, wird nur einmal geholt.
sort -u "$work/filenames" > "$work/filenames.uniq"
count=$(wc -l < "$work/filenames.uniq" | tr -d ' ')
[[ "$count" -gt 0 ]] || fail 'no Filename entry in any published index'
while IFS= read -r deb; do
  [[ -n "$deb" ]] || continue
  case "$deb" in
    /*|*..*) fail "unsafe Filename entry in a published index: $deb" ;;
  esac
  get "${prefix}/${deb}" "$work/package.deb" 536870912
  local_deb="$archive_dir/${deb}"
  [[ -f "$local_deb" && ! -L "$local_deb" ]] \
    || fail "the local package is missing: $local_deb"
  cmp -s "$work/package.deb" "$local_deb" \
    || fail "the published $deb differs from the local file"
  step "    ${deb} identisch"
done < "$work/filenames.uniq"
step "    ${count} Paket(e) geprueft"

printf 'publication verified against %s\n' "$base_url"
