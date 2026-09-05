#!/usr/bin/env bash
# Run only in the disposable integration container, with /archive test fixtures.
set -euo pipefail
printf 'deb [signed-by=/archive/example-archive-keyring.pgp] file:/archive rolling main\n' > /tmp/archive.list
opts=(-o Dir::Etc::sourcelist=/tmp/archive.list -o Dir::Etc::sourceparts=-
      -o APT::Architectures::=amd64 -o APT::Architectures::=arm64
      -o APT::Update::Error-Mode=any)
apt-get "${opts[@]}" update
for package in alpha:amd64 alpha:arm64 beta; do
  apt-cache "${opts[@]}" policy "$package" | tee /tmp/policy
  grep -F 'Candidate: 1.0' /tmp/policy
done
mkdir /tmp/packages
chown _apt /tmp/packages
cd /tmp/packages
apt-get "${opts[@]}" download alpha:amd64 alpha:arm64 beta
for path in *.deb; do
  expected=$(find /archive/pool -name "$path")
  test -n "$expected"
  cmp "$path" "$expected"
done
# Clear cached lists so a failed fetch cannot masquerade as package visibility.
mkdir /tmp/negative-lists
printf 'invalid keyring\n' > /tmp/wrong.pgp
sed 's@/archive/example-archive-keyring.pgp@/tmp/wrong.pgp@' /tmp/archive.list > /tmp/wrong.list
if apt-get "${opts[@]}" -o Dir::Etc::sourcelist=/tmp/wrong.list \
    -o Dir::State::lists=/tmp/negative-lists update; then
  echo 'invalid trust anchor unexpectedly accepted' >&2
  exit 1
fi
printf 'Real APT: both native architectures and portable package verified; wrong key rejected.\n'
