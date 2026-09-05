#!/usr/bin/env bash
# Contract tests for the renderer. No network, no key, no dpkg.
set -uo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)
render="$root/scripts/render_archive.py"
validate_time="$root/scripts/release_time.py"
mkdeb="$root/tests/make_deb.py"
work=$(mktemp -d); trap 'rm -rf -- "$work"' EXIT
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

manifest() {  # $1 = target file, $2... = additional lines
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

deb() {  # $1 = directory, then make_deb arguments
  local dir=$1; shift
  python3 "$mkdeb" --out "$dir/$(python3 - "$@" <<'PY'
import sys
a=dict(zip(sys.argv[1::2], sys.argv[2::2]))
print(f"{a['--package']}_{a['--version']}_{a['--architecture']}.deb")
PY
)" "$@"
}

run() { python3 "$render" "$@" 2>&1; }

# A renderer that aborts after partial output must not run into the greps
# below: the messages would then mislead instead of being clear.
must_run() {  # $1 = test name, then the renderer arguments
  local name=$1; shift
  local out
  if out=$(run "$@"); then return 0; fi
  bad "$name" "the renderer aborted: $(printf '%s' "$out" | head -1)"
  return 1
}

EPOCH=1700000000

wrapper="$root/scripts/render-archive.sh"
check "the wrapper creates its staging atomically with mktemp" \
  "$(grep -c 'staging=$(mktemp -d ' "$wrapper")" "1"
check "the wrapper uses no predictable PID path" \
  "$(grep -Fc '.render.$$' "$wrapper")" "0"

# ---------------------------------------------------------------- T1
t="T1  several packages, several versions, several architectures"
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
  check "$t: pool objects"     "$(find "$o/pool" -name '*.deb' | wc -l | tr -d ' ')" "12"
  check "$t: pool path"        "$([ -f "$o/pool/main/d/demo/demo_2.0.0_amd64.deb" ] && echo yes || echo no)" "yes"
  check "$t: stanzas amd64"    "$(grep -c '^Package:' "$o/dists/rolling/main/binary-amd64/Packages")" "6"
  check "$t: stanzas arm64"    "$(grep -c '^Package:' "$o/dists/rolling/main/binary-arm64/Packages")" "6"
  check "$t: no foreign arch"  "$(grep -c 'arm64' "$o/dists/rolling/main/binary-amd64/Packages")" "0"
fi

# ---------------------------------------------------------------- T2
t="T2  by-hash exists for every hash named in Release"
rel="$o/dists/rolling/Release"
algs=$(grep -E '^(SHA256|SHA512|MD5Sum|SHA1):$' "$rel" | tr -d ':' | sort | tr '\n' ' ')
check "$t: hash fields"       "$(echo $algs)" "SHA256 SHA512"
b="$o/dists/rolling/main/binary-amd64"
for alg in SHA256 SHA512; do
  low=$(echo "$alg" | tr 'A-Z' 'a-z')
  miss=0
  for f in Packages Packages.gz; do
    h=$(python3 -c "import hashlib,sys;print(hashlib.new('$low',open(sys.argv[1],'rb').read()).hexdigest())" "$b/$f")
    [ -f "$b/by-hash/$alg/$h" ] || miss=$((miss+1))
  done
  check "$t: $alg complete" "$miss" "0"
done

# ---------------------------------------------------------------- T3
t="T3  Release is complete and deterministic"
check "$t: Acquire-By-Hash"  "$(grep -c '^Acquire-By-Hash: yes$' "$rel")" "1"
check "$t: Suite"            "$(grep -c '^Suite: rolling$' "$rel")" "1"
check "$t: Valid-Until"      "$(grep -c '^Valid-Until: ' "$rel")" "1"
check "$t: no by-hash inside" "$(grep -c 'by-hash' "$rel")" "0"
if python3 "$validate_time" --manifest "$m" --release "$rel" \
    --publication-epoch "$EPOCH" --now-epoch "$EPOCH" --max-age-seconds 0; then
  ok "$t: Date and Valid-Until exactly from the publication epoch"
else
  bad "$t: Date and Valid-Until exactly from the publication epoch"
fi
o2="$work/t1out2"
must_run "$t" --manifest "$m" --project demo --pool-dir "$p" \
  --output-dir "$o2" --publication-epoch $EPOCH || true
if diff -r "$o" "$o2" >/dev/null 2>&1; then ok "$t: two runs byte-identical"
else bad "$t: two runs byte-identical" "$(diff -rq "$o" "$o2" | head -3)"; fi

later_epoch=$((EPOCH + 86400))
o3="$work/t1out3"
must_run "$t" --manifest "$m" --project demo --pool-dir "$p" \
  --output-dir "$o3" --publication-epoch "$later_epoch" || true
if diff -r "$o/pool" "$o3/pool" >/dev/null 2>&1; then
  ok "$t: a new epoch leaves the pool untouched"
else
  bad "$t: a new epoch leaves the pool untouched"
fi
if diff -r "$o/dists/rolling/main" "$o3/dists/rolling/main" >/dev/null 2>&1; then
  ok "$t: a new epoch leaves indexes and by-hash untouched"
else
  bad "$t: a new epoch leaves indexes and by-hash untouched"
fi
if cmp -s "$rel" "$o3/dists/rolling/Release"; then
  bad "$t: a new epoch changes Release"
else
  ok "$t: a new epoch changes Release"
fi
if diff <(sed '/^Date: /d; /^Valid-Until: /d' "$rel") \
        <(sed '/^Date: /d; /^Valid-Until: /d' "$o3/dists/rolling/Release") \
        >/dev/null 2>&1; then
  ok "$t: only the time fields in Release change"
else
  bad "$t: only the time fields in Release change"
fi
if python3 "$validate_time" --manifest "$m" \
    --release "$o3/dists/rolling/Release" --publication-epoch "$later_epoch" \
    --now-epoch "$later_epoch" --max-age-seconds 0; then
  ok "$t: the later epoch and the 180-day window are exact"
else
  bad "$t: the later epoch and the 180-day window are exact"
fi
expired_now=$((EPOCH + 180 * 86400))
msg=$(python3 "$validate_time" --manifest "$m" --release "$rel" \
        --publication-epoch "$EPOCH" --now-epoch "$expired_now" 2>&1)
if printf '%s' "$msg" | grep -qF 'Release expired at'; then
  ok "$t: an expired Valid-Until is rejected by the calendar"
else
  bad "$t: an expired Valid-Until is rejected by the calendar" \
    "$(printf '%s' "$msg" | head -1)"
fi

# The absolute output path must carry no meaning for the Release selection. A
# parent directory named by-hash must not swallow any index.
byhash_parent="$work/by-hash"; mkdir -p "$byhash_parent"
byhash_out="$byhash_parent/archive"
if must_run "$t" --manifest "$m" --project demo --pool-dir "$p" \
    --output-dir "$byhash_out" --publication-epoch $EPOCH; then
  check "$t: by-hash in the absolute path removes no index" \
    "$(grep -c 'main/binary-amd64/Packages.gz$' "$byhash_out/dists/rolling/Release")" "2"
fi

# ---------------------------------------------------------------- T4
t="T4  Architecture: all lands in every binary index"
m4="$work/t4.toml"; manifest "$m4"
p4="$work/t4pool"; mkdir -p "$p4"
deb "$p4" --package demo --version 1.0.0 --architecture amd64
deb "$p4" --package demo --version 1.0.0 --architecture arm64
deb "$p4" --package demo-extras --version 1.0.0 --architecture all
o4="$work/t4out"
if must_run "$t" --manifest "$m4" --project demo --pool-dir "$p4" \
    --output-dir "$o4" --publication-epoch $EPOCH; then
for a in amd64 arm64; do
  check "$t: $a contains all" \
    "$(grep -c '^Architecture: all$' "$o4/dists/rolling/main/binary-$a/Packages")" "1"
  check "$t: $a Stanzas" \
    "$(grep -c '^Package:' "$o4/dists/rolling/main/binary-$a/Packages")" "2"
done
fi

# ---------------------------------------------------------------- T5
t="T5  an empty index for a served architecture without a package"
m5="$work/t5.toml"; manifest "$m5"
p5="$work/t5pool"; mkdir -p "$p5"
deb "$p5" --package demo --version 1.0.0 --architecture amd64
o5="$work/t5out"
must_run "$t" --manifest "$m5" --project demo --pool-dir "$p5" \
  --output-dir "$o5" --publication-epoch $EPOCH || true
check "$t: the arm64 index exists" "$([ -f "$o5/dists/rolling/main/binary-arm64/Packages" ] && echo yes || echo no)" "yes"
check "$t: the arm64 index is empty" "$(wc -c < "$o5/dists/rolling/main/binary-arm64/Packages" | tr -d ' ')" "0"
# Every index appears once per hash section, so twice with SHA256 and SHA512.
check "$t: arm64 in Release"       "$(grep -c 'binary-arm64/Packages$' "$o5/dists/rolling/Release")" "2"

# ---------------------------------------------------------------- T6  Rejections
reject() {  # $1 = name, $2 = expected text fragment, then setup via callback
  local name=$1 want=$2; shift 2
  local msg; msg=$("$@" 2>&1)
  if printf '%s' "$msg" | grep -qF "$want"; then ok "T6  $name"
  else bad "T6  $name" "expected a message with [$want], got: $(printf '%s' "$msg" | head -1)"; fi
}

mk_unknown_pkg() {
  local d=$work/r1; mkdir -p "$d/pool"; manifest "$d/m.toml"
  deb "$d/pool" --package otherpackage --version 1.0.0 --architecture amd64
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "an unknown package name is rejected" "does not list" mk_unknown_pkg

mk_unknown_arch() {
  local d=$work/r2; mkdir -p "$d/pool"; manifest "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture riscv64
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "an unserved architecture is rejected" "does not serve" mk_unknown_arch

mk_duplicate() {
  local d=$work/r3; mkdir -p "$d/pool"; manifest "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture amd64
  cp "$d/pool/demo_1.0.0_amd64.deb" "$d/pool/copy.deb"
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "a duplicate identity is rejected" "both provide" mk_duplicate

mk_unknown_project() {
  local d=$work/r4; mkdir -p "$d/pool"; manifest "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture amd64
  run --manifest "$d/m.toml" --project gibtesnicht --pool-dir "$d/pool" --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "an unknown project is rejected" "not declared exactly once" mk_unknown_project

mk_byhash_off() {
  local d=$work/r5; mkdir -p "$d/pool"; manifest "$d/m.toml"
  sed -i.bak 's/acquire_by_hash = true/acquire_by_hash = false/' "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture amd64
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "by-hash switched off is rejected" "acquire_by_hash must stay enabled" mk_byhash_off

mk_existing_out() {
  local d=$work/r6; mkdir -p "$d/pool" "$d/out"; manifest "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture amd64
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "an existing output directory is rejected" "must be a new path" mk_existing_out

mk_unsafe_version() {
  local d=$work/r7; mkdir -p "$d/pool"; manifest "$d/m.toml"
  python3 "$mkdeb" --out "$d/pool/evil.deb" --package demo \
    --version '1.0/../../../../../../escaped/y' --architecture amd64
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" \
    --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "path traversal in the version is rejected" "unsafe version" mk_unsafe_version

mk_unsafe_source() {
  local d=$work/r8; mkdir -p "$d/pool"; manifest "$d/m.toml"
  python3 "$mkdeb" --out "$d/pool/evil.deb" --package demo --version 1.0.0 \
    --architecture amd64 --source '../../../../escaped/source'
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" \
    --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "path traversal in the source is rejected" "unsafe source name" mk_unsafe_source

mk_computed_field() {
  local field=$1 d="$work/computed.$1"; mkdir -p "$d/pool"; manifest "$d/m.toml"
  python3 "$mkdeb" --out "$d/pool/evil.deb" --package demo --version 1.0.0 \
    --architecture amd64 --extra "$field=forged"
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" \
    --output-dir "$d/out" --publication-epoch $EPOCH
}
for field in Filename Size SHA256 SHA512; do
  reject "the archive-computed control field $field is rejected" \
    "archive-computed control fields: $field" mk_computed_field "$field"
done

mk_all_native_conflict() {
  local d=$work/r9; mkdir -p "$d/pool"; manifest "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture all
  deb "$d/pool" --package demo --version 1.0.0 --architecture amd64
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" \
    --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "Architecture all and native of the same version are rejected" \
  "provided both as Architecture: all and as a native package" mk_all_native_conflict

mk_damaged() {
  local fixture=$1 d="$work/damaged.$1"; mkdir -p "$d/pool"; manifest "$d/m.toml"
  python3 "$mkdeb" --out "$d/pool/damaged.deb" --package demo --version 1.0.0 \
    --architecture amd64 --fixture "$fixture"
  run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" \
    --output-dir "$d/out" --publication-epoch $EPOCH
}
reject "wrong ar magic is rejected" "no ar archive signature" \
  mk_damaged bad-ar-magic
reject "a truncated ar header is rejected" "truncated ar member header" \
  mk_damaged truncated-ar-header
reject "a repeated ar member is rejected" "repeats or omits an ar member name" \
  mk_damaged duplicate-ar-member
reject "wrong ar padding is rejected" "malformed ar member padding" \
  mk_damaged bad-ar-padding
reject "damaged compression is rejected" "cannot decompress control metadata" \
  mk_damaged corrupt-control-compression
reject "a damaged control tar is rejected" "cannot parse control archive" \
  mk_damaged corrupt-control-tar
reject "a missing control file is rejected" "exactly one regular control file" \
  mk_damaged missing-control
reject "a duplicate control file is rejected" "exactly one regular control file" \
  mk_damaged duplicate-control
reject "a control symlink is rejected" "not a bounded regular file" \
  mk_damaged symlink-control
reject "control without a terminating line is rejected" "unsafe Debian control metadata" \
  mk_damaged control-no-newline
reject "control with a NUL is rejected" "unsafe Debian control metadata" \
  mk_damaged control-nul

# ---------------------------------------------------------------- T7
# Manifest values are checked, not converted. `bool("false")` is True and
# `int(True)` is 1; a conversion would turn a typo into a silently wrong
# archive.
t="T7  manifest types are checked instead of converted"
t7() {  # $1 = sed expression on the manifest, $2 = expected text fragment
  local d="$work/t7.$RANDOM"; mkdir -p "$d/pool"
  manifest "$d/m.toml"
  sed -i.bak "$1" "$d/m.toml"
  deb "$d/pool" --package demo --version 1.0.0 --architecture amd64
  local msg
  msg=$(run --manifest "$d/m.toml" --project demo --pool-dir "$d/pool" \
          --output-dir "$d/out" --publication-epoch $EPOCH 2>&1)
  if printf '%s' "$msg" | grep -qF "$2"; then ok "$t: $3"
  else bad "$t: $3" "expected [$2], got: $(printf '%s' "$msg" | head -1)"; fi
}
t7 's/acquire_by_hash = true/acquire_by_hash = "false"/' \
   'acquire_by_hash must be bool, not str' 'a string instead of a bool'
t7 's/valid_until_days = 180/valid_until_days = true/' \
   'valid_until_days must be int, not bool' 'a bool instead of an int'
t7 's/valid_until_days = 180/valid_until_days = "180"/' \
   'valid_until_days must be int, not str' 'a string instead of an int'
t7 's/valid_until_days = 180/valid_until_days = 1/' \
   'valid_until_days must cover at least a week' 'a validity window that is too short'
t7 's/components = \["main"\]/components = [1]/' \
   'components must hold only strings' 'a number in a list of strings'

# ---------------------------------------------------------------- T8
# A line break in a field that is written into the Release file appends an
# arbitrary further line to it.
t="T8  Release fields must contain no control characters"
t7 's|origin = "example"|origin = "example\\nSuite: evil"|' \
   'origin must be one printable line' 'a line break in origin'
t7 's|origin = "example"|origin = "exa\\tmple"|' \
   'origin must be one printable line' 'a tab in origin'

unsafe_project=$'demo\nLabel: evil'
msg=$(run --manifest "$m" --project "$unsafe_project" --pool-dir "$p" \
        --output-dir "$work/unsafe-project" --publication-epoch $EPOCH 2>&1)
if printf '%s' "$msg" | grep -qF 'project name must be one safe printable field'; then
  ok "$t: a line break in the project name"
else
  bad "$t: a line break in the project name" "$(printf '%s' "$msg" | head -1)"
fi

prefix_manifest="$work/unsafe-prefix.toml"; manifest "$prefix_manifest"
sed -i.bak 's|prefix = "/demo"|prefix = "/demo\\nValid-Until: Thu, 01 Jan 2099 00:00:00 +0000"|' \
  "$prefix_manifest"
msg=$(run --manifest "$prefix_manifest" --project demo --pool-dir "$p" \
        --output-dir "$work/unsafe-prefix" --publication-epoch $EPOCH 2>&1)
if printf '%s' "$msg" | grep -qF 'unsafe prefix'; then
  ok "$t: a line break in the prefix"
else
  bad "$t: a line break in the prefix" "$(printf '%s' "$msg" | head -1)"
fi

printf '\n  passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
