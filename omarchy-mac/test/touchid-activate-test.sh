#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Touch ID reads "ready" only after the first open of /dev/sep-bio, so a udev
# rule starts a unit that opens it once as soon as the kernel publishes it.
"$ROOT/install" "$work/root"
rule=$work/root/usr/lib/udev/rules.d/94-omarchy-mac-touchid.rules
unit=$work/root/usr/lib/systemd/system/omarchy-mac-touchid-activate.service
[[ -f $rule && -f $unit ]] || fail 'the Touch ID rule and unit are staged'
grep -Fxq 'ACTION=="add", SUBSYSTEM=="misc", KERNEL=="sep-bio", TAG+="systemd", ENV{SYSTEMD_WANTS}+="omarchy-mac-touchid-activate.service"' "$rule" ||
  fail 'the rule starts the unit when the Secure Enclave publishes sep-bio, and only then'
[[ $(grep -v '^#' "$rule") != *RUN* ]] || fail 'the rule runs nothing itself'
grep -Fxq 'StandardInput=file:/dev/sep-bio' "$unit" && grep -Fxq 'Type=oneshot' "$unit" &&
  grep -Fxq 'ConditionPathExists=/dev/sep-bio' "$unit" ||
  fail 'the unit opens /dev/sep-bio once, and only where it exists'
! grep -q '^\[Install\]' "$unit" || fail 'the unit needs no enabling: the rule pulls it in'
pass 'the Touch ID rule and unit are staged, and the rule alone starts the unit'

if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
  udevadm verify --no-style "$rule" >/dev/null || fail 'udevadm accepts the rule'
  pass 'udevadm accepts the Touch ID rule'
fi
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify --man=no "$unit" 2>"$work/verify" || fail 'systemd accepts the unit' "$(cat "$work/verify")"
  pass 'systemd accepts the Touch ID unit'
fi
