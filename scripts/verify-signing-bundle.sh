#!/usr/bin/env bash
# Prueft das importierte Schluesselmaterial, bevor damit signiert wird.
#
# Erwartet wird ein Bundle, das nur geheime Subkeys enthaelt: der
# zertifizierende Primaerschluessel bleibt offline und darf nie in CI liegen.
# Feld 15 des sec-Datensatzes ist '#', wenn der geheime Primaer fehlt, und '+',
# wenn er vorhanden ist. Dieses eine Zeichen ist der einzige maschinell
# pruefbare Nachweis dafuer, deshalb wird es erzwungen und nicht dokumentiert.
#
# Uebernommen aus metaneutrons/aros-tools, wo diese Logik mit CI-gedeckten
# Mutationstests belegt ist; der Subkey ist hier verpflichtend statt optional,
# weil jede Archiv-Domain genau einen hat.
set -euo pipefail

fail() { printf '::error::AR120 %s\n' "$*" >&2; exit 1; }

# Ein `shift 2` ohne Wert bricht mit bashs eigener Meldung ab, und bei
# `set -e` sogar lautlos: Exitcode 1, keine Ausgabe auf stdout oder stderr. In
# einem Workflow bliebe nur "Process completed with exit code 1" stehen.
opt_value() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"; }

homedir=''; fingerprint=''; signing_subkey=''
while (($#)); do
  case "$1" in
    --homedir)        opt_value "$@"; homedir=$2; shift 2 ;;
    --fingerprint)    opt_value "$@"; fingerprint=$2; shift 2 ;;
    --signing-subkey) opt_value "$@"; signing_subkey=$2; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ -d "$homedir" && ! -L "$homedir" ]] || fail 'GnuPG home must be a real directory'
for name in fingerprint signing_subkey; do
  value=${!name}
  [[ "$value" =~ ^[0-9A-Fa-f]{40}$ ]] || \
    fail "--${name//_/-} must be a full 40-hex fingerprint, got '${value}'"
done
fingerprint=${fingerprint^^}
signing_subkey=${signing_subkey^^}

# Genau ein aktiver Primaerschluessel, und es muss der erwartete sein.
# Die Regex nutzt `+` statt eines Intervalls: mawk kennt {n} nicht, und Debian
# 13 liefert mawk als Standard-awk.
measured=$(gpg --no-options --batch --homedir "$homedir" --with-colons \
  --list-secret-keys --fingerprint | awk -F: '
    $1 == "sec" { secret_keys += 1; validity = $2; next }
    $1 == "fpr" && secret_keys == 1 && !measured { measured = toupper($10) }
    END {
      if (secret_keys != 1 || length(measured) != 40 ||
          measured !~ /^[0-9A-F]+$/ || validity ~ /^[redi]$/) exit 1
      print measured
    }') || fail 'bundle must contain exactly one active primary secret key'
[[ "$measured" == "$fingerprint" ]] || \
  fail "bundle has primary $measured, manifest names $fingerprint"

gpg --no-options --batch --homedir "$homedir" --with-colons \
  --list-secret-keys --fingerprint | awk -F: -v want="$signing_subkey" '
    $1 == "sec" { primary_stub = ($15 == "#"); next }
    $1 == "ssb" { current = $15; next }
    $1 == "fpr" && current != "" {
      if (toupper($10) == want && current == "+") subkey_present = 1
      current = ""
      next
    }
    END {
      if (!primary_stub) {
        print "::error::AR120 primary secret key is present; export secret subkeys only" > "/dev/stderr"
        exit 1
      }
      if (!subkey_present) {
        print "::error::AR120 the named signing subkey is not in the bundle" > "/dev/stderr"
        exit 1
      }
    }' || fail 'bundle does not have the required subkey-only shape'

printf 'signing bundle verified: primary %s offline, subkey %s present\n' \
  "$fingerprint" "$signing_subkey"
