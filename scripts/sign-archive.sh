#!/usr/bin/env bash
# Signiert einen gerenderten Archivbaum und legt den Keyring der Domain daneben.
#
#   sign-archive.sh --manifest domains/<host>/manifest.toml \
#                   --archive-dir <wurzel eines projekts> \
#                   --private-key <datei> --passphrase-file <datei> \
#                   --publication-epoch <epoch>
#
# Erzeugt neben dists/<suite>/Release:
#   dists/<suite>/InRelease      geklarsignt
#   dists/<suite>/Release.gpg    abgetrennt, armored
# und im Archivwurzelverzeichnis den auf genau diesen Subkey minimierten
# Keyring, armored und dearmored.
#
# Der Aufrufer besitzt das Schluesselmaterial; dieses Skript raeumt es auf.
set -euo pipefail

fail() { printf '::error::AR130 %s\n' "$*" >&2; exit 1; }

# Ein `shift 2` ohne Wert bricht mit bashs eigener Meldung ab, und bei
# `set -e` sogar lautlos: Exitcode 1, keine Ausgabe auf stdout oder stderr. In
# einem Workflow bliebe nur "Process completed with exit code 1" stehen.
opt_value() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"; }

manifest=''; archive_dir=''; private_key=''; passphrase_file=''; publication_epoch=''
while (($#)); do
  case "$1" in
    --manifest)        opt_value "$@"; manifest=$2; shift 2 ;;
    --archive-dir)     opt_value "$@"; archive_dir=$2; shift 2 ;;
    --private-key)     opt_value "$@"; private_key=$2; shift 2 ;;
    --passphrase-file) opt_value "$@"; passphrase_file=$2; shift 2 ;;
    --publication-epoch) opt_value "$@"; publication_epoch=$2; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
for name in manifest archive_dir private_key passphrase_file publication_epoch; do
  [[ -n "${!name}" ]] || fail "--${name//_/-} is required"
done
for command in gpg gpgv gpgconf python3; do
  command -v "$command" >/dev/null || fail "required command is missing: $command"
done
[[ -f "$manifest"        && ! -L "$manifest"        ]] || fail 'manifest must be a regular file'
[[ -d "$archive_dir"     && ! -L "$archive_dir"     ]] || fail 'archive-dir must be a real directory'
[[ -f "$private_key"     && ! -L "$private_key"     ]] || fail 'private-key must be a regular file'
[[ -f "$passphrase_file" && ! -L "$passphrase_file" ]] || fail 'passphrase-file must be a regular file'
[[ "$publication_epoch" =~ ^[1-9][0-9]*$ ]] || fail 'publication-epoch must be a positive integer'

script_root=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
archive_dir=$(unset CDPATH; cd -- "$archive_dir" && pwd -P)

read -r fingerprint signing_subkey suite keyring_package < <(
  MANIFEST="$manifest" python3 - <<'PY'
import os, sys, tomllib
with open(os.environ["MANIFEST"], "rb") as handle:
    data = tomllib.load(handle)
def need(section, key):
    block = data.get(section)
    if not isinstance(block, dict) or not isinstance(block.get(key), str):
        raise SystemExit(f"[{section}] {key} must be a string")
    value = block[key]
    if value == "TBD":
        raise SystemExit(f"[{section}] {key} is still TBD; generate the key first")
    return value
print(need("signing", "primary_fingerprint"),
      need("signing", "signing_subkey"),
      need("release", "suite"),
      need("domain", "keyring_package"))
PY
) || fail 'manifest does not carry usable signing values'

for value in "$fingerprint" "$signing_subkey"; do
  [[ "$value" =~ ^[0-9A-Fa-f]{40}$ ]] || fail "manifest fingerprint is malformed: $value"
done
fingerprint=$(printf '%s' "$fingerprint" | LC_ALL=C tr '[:lower:]' '[:upper:]')
signing_subkey=$(printf '%s' "$signing_subkey" | LC_ALL=C tr '[:lower:]' '[:upper:]')
release="$archive_dir/dists/$suite/Release"
[[ -f "$release" && ! -L "$release" ]] || fail "rendered Release is missing: $release"

# Die freie Epoche macht den Renderer reproduzierbar. Signiert werden darf
# aber nur ein frischer Baum, dessen beide Zeitfelder exakt aus derselben
# Publikationszeit stammen. Der 45-Minuten-Workflow bleibt im 60-Minuten-Fenster.
time_validator="$script_root/release_time.py"
[[ -f "$time_validator" && ! -L "$time_validator" ]] \
  || fail 'Release time validator is missing or unsafe'
python3 "$time_validator" --manifest "$manifest" --release "$release" \
  --publication-epoch "$publication_epoch" --max-age-seconds 3600 \
  || fail 'Release time validation failed before signing'

# gpg-agent legt einen Unix-Socket unter GNUPGHOME an; unter macOS reisst ein
# langer Pfad die sockaddr_un-Grenze, deshalb bewusst unter /tmp.
gnupg_home=$(mktemp -d /tmp/apt-archive-gpg.XXXXXX)
chmod 0700 "$gnupg_home"
cleanup() {
  gpgconf --homedir "$gnupg_home" --kill gpg-agent >/dev/null 2>&1 || true
  rm -rf -- "$gnupg_home"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

gpg --batch --homedir "$gnupg_home" --import "$private_key" >/dev/null 2>&1 \
  || fail 'cannot import the signing bundle'

verifier="$script_root/verify-signing-bundle.sh"
[[ -x "$verifier" && ! -L "$verifier" ]] || fail 'bundle verifier is missing or unsafe'
"$verifier" --homedir "$gnupg_home" --fingerprint "$fingerprint" \
  --signing-subkey "$signing_subkey" >/dev/null \
  || fail 'the imported bundle is not the one the manifest names'

# gpg signiert nicht mit einem Schluessel, der aus Sicht der gefaelschten Zeit
# noch nicht existierte, und meldet dann nur "Unbrauchbarer geheimer
# Schluessel". Deshalb hier benannt pruefen statt spaeter raten.
#
# Praktische Folge: ein alter Baum wird zum Nachsignieren mit einer frischen
# Publikationszeit neu gerendert. Date, Valid-Until und Signaturzeit ruecken
# dabei gemeinsam vor.
created=$(gpg --no-options --batch --homedir "$gnupg_home" --with-colons \
  --list-secret-keys --fingerprint | awk -F: -v want="$signing_subkey" '
    $1 == "ssb" { stamp = $6; next }
    $1 == "fpr" && stamp != "" {
      if (toupper($10) == want) { print stamp; exit }
      stamp = ""
    }')
[[ "$created" =~ ^[0-9]+$ ]] || fail 'cannot read the signing subkey creation time'
if (( publication_epoch < created )); then
  fail "publication-epoch $publication_epoch precedes the subkey creation $created; \
gpg would refuse to sign with a key that does not yet exist at that time"
fi

# Das abschliessende Ausrufezeichen ist an beiden Stellen zwingend. Ohne es
# waehlt gpg bei mehreren Signing-Subkeys selbst einen aus, und der Export
# liefert alle Subkeys statt des einen, der zu dieser Domain gehoert.
signer=("--local-user" "${signing_subkey}!")
common=(--batch --homedir "$gnupg_home" --yes --pinentry-mode loopback
        --passphrase-file "$passphrase_file"
        --faked-system-time "${publication_epoch}!")

gpg "${common[@]}" "${signer[@]}" --armor --detach-sign \
  --output "$archive_dir/dists/$suite/Release.gpg" "$release" \
  || fail 'detached signature failed'
gpg "${common[@]}" "${signer[@]}" --armor --clearsign \
  --output "$archive_dir/dists/$suite/InRelease" "$release" \
  || fail 'clearsigned InRelease failed'

# Auf genau diesen Subkey minimiert, damit ein Client nicht das ganze
# Zertifikat mit allen Domain-Subkeys als vertrauenswuerdig einlesen muss.
armored="$archive_dir/${keyring_package}.asc"
dearmored="$archive_dir/${keyring_package}.pgp"
gpg --no-options --batch --homedir "$gnupg_home" --armor --no-emit-version \
  --no-comments --export "${signing_subkey}!" > "$armored" \
  || fail 'keyring export failed'
gpg --no-options --batch --homedir "$gnupg_home" --no-emit-version \
  --export "${signing_subkey}!" > "$dearmored" \
  || fail 'dearmored keyring export failed'
if ! subkeys=$(gpg --no-options --batch --with-colons --show-keys "$dearmored" |
                 awk -F: '$1 == "sub" { count += 1 } END { print count + 0 }'); then
  fail 'cannot inspect the exported keyring'
fi
[[ "$subkeys" == 1 ]] || fail "exported keyring carries $subkeys subkeys, expected exactly 1"
chmod 0644 "$armored" "$dearmored" \
  "$archive_dir/dists/$suite/InRelease" "$archive_dir/dists/$suite/Release.gpg"

# Gegen den ausgelieferten Keyring pruefen, nicht gegen den Signierschluessel:
# geprueft wird, was ein Client tatsaechlich bekommt.
# Eine abgetrennte Signatur braucht die Datendatei als zweites Argument, eine
# geklarsignte nicht. Das ausgeschrieben, weil ein Einzeiler den Unterschied
# verdeckt und ein falscher Aufruf hier stillschweigend nichts pruefen wuerde.
verify_signature() {  # $1 = Name, danach gpgv-Argumente
  local label=$1 status signature_epoch
  shift
  status=$(gpgv --keyring "$dearmored" --status-fd 1 "$@" 2>/dev/null) \
    || fail "gpgv rejected $label against the shipped keyring"
  signature_epoch=$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" {print $5}')
  [[ "$signature_epoch" == "$publication_epoch" ]] \
    || fail "$label signature time $signature_epoch does not equal publication epoch $publication_epoch"
}
verify_signature Release.gpg "$archive_dir/dists/$suite/Release.gpg" "$release"
verify_signature InRelease "$archive_dir/dists/$suite/InRelease"

printf 'signed %s with subkey %s, keyring %s\n' \
  "dists/$suite/Release" "$signing_subkey" "${keyring_package}.pgp"
