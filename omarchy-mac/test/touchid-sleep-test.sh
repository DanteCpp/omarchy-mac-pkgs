#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A sleep that starts while the lock screen waits for a finger leaves fprintd
# holding Touch ID after resume, so a system-sleep hook stops it first.
"$ROOT/install" "$work/root"
hook=$work/root/usr/lib/systemd/system-sleep/omarchy-mac-touchid
[[ -L $hook && $(readlink "$hook") == "../../omarchy-mac/touchid-sleep" ]] ||
  fail 'the sleep hook is a link to the staged helper'
[[ -x $(readlink -f "$hook") ]] || fail 'systemd-sleep can run the hook: its helper is executable'
pass 'the Touch ID sleep hook is staged and executable'

mkdir -p "$work/bin"
cat >"$work/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
echo aarch64-apple
STUB
stub_apple_predicate "$work/bin"
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >>"$CALLS"
[[ $* == "--quiet is-active fprintd.service" ]] && exit "$ACTIVE"
[[ $1 == stop ]] && exit "$STOP"
exit 0
STUB
cat >"$work/bin/timeout" <<'STUB'
#!/bin/bash
shift
exec "$@"
STUB
printf '#!/bin/sh\nexit 0\n' >"$work/bin/sleep"
chmod +x "$work/bin/"*
export CALLS=$work/calls
run() {
  : >"$CALLS"
  ACTIVE=$1 STOP=$2 PATH="$work/bin:$PATH" "$ROOT/lib/touchid-sleep" "$3"
}
run 0 0 pre || fail 'the hook succeeds before sleep'
grep -Fxq 'systemctl stop fprintd.service' "$CALLS" || fail 'a running fprintd is stopped before sleep'
run 3 0 pre || fail 'the hook succeeds with fprintd not running'
! grep -q 'stop' "$CALLS" || fail 'fprintd that is not running is left alone'
run 0 1 pre || fail 'a stop that fails never fails the sleep'
run 0 0 post || fail 'the hook succeeds after resume'
[[ ! -s $CALLS ]] || fail 'after resume the hook does nothing: D-Bus starts fprintd when it is asked for'
pass 'the hook stops a running fprintd before sleep only, and never fails the sleep'
