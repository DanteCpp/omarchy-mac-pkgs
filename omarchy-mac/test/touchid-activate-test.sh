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
# Verified inside the staged root, whose stub commands stand in for the
# runtime's platform check, so the result never depends on the host.
if command -v systemd-analyze >/dev/null; then
  mkdir -p "$work/root/usr/bin"
  for command in omarchy-hw-apple-silicon true; do
    printf '#!/bin/sh\nexit 0\n' >"$work/root/usr/bin/$command"
    chmod +x "$work/root/usr/bin/$command"
  done
  systemd-analyze --root="$work/root" verify --man=no /usr/lib/systemd/system/omarchy-mac-touchid-activate.service 2>"$work/verify" ||
    fail 'systemd accepts the unit' "$(cat "$work/verify")"
  pass 'systemd accepts the Touch ID unit'
fi
