#!/usr/bin/env bash
# Checks the imported key material before anything is signed with it.
#
# What is expected is a bundle holding secret subkeys only: the certifying
# primary key stays offline and must never sit in CI. Field 15 of the sec record
# is '#' when the secret primary is absent and '+' when it is present. That one
# character is the only machine-checkable evidence for it, which is why it is
# enforced rather than documented.
#
# Taken from metaneutrons/aros-tools, where this logic is backed by mutation
# tests under CI; here the subkey is mandatory rather than optional, because
# every archive domain has exactly one.
set -euo pipefail

fail() { printf '::error::AR120 %s\n' "$*" >&2; exit 1; }

# A `shift 2` without a value aborts with bash's own message, and under
# `set -e` even silently: exit code 1, nothing on stdout or stderr. In a
# workflow all that would remain is "Process completed with exit code 1".
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
fingerprint=$(printf '%s' "$fingerprint" | LC_ALL=C tr '[:lower:]' '[:upper:]')
signing_subkey=$(printf '%s' "$signing_subkey" | LC_ALL=C tr '[:lower:]' '[:upper:]')

# Exactly one active primary key, and it has to be the expected one.
# The regex uses `+` rather than an interval: mawk does not know {n}, and Debian
# 13 ships mawk as the default awk.
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
