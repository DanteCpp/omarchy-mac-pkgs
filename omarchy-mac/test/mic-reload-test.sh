#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
watcher=
cleanup() {
  [[ -z $watcher ]] || kill "$watcher" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/bin" "$work/run" "$work/state"
printf '#!/bin/bash\necho "${PLATFORM:-aarch64-apple}"\n' >"$work/bin/omarchy-hw-platform"
stub_apple_predicate "$work/bin"
# The subscriber records its PID and waits; nothing else answers.
cat >"$work/bin/pactl" <<'STUB'
#!/bin/bash
[[ $1 == "subscribe" ]] || exit 1
echo $$ >"$WORK/subscriber"
exec sleep 60
STUB
chmod +x "$work/bin/"*

# A package upgrade replaces the running watcher's file: the watcher runs the
# new file under its own PID with its arguments, and stops its subscriber.
"$ROOT"/install "$work/root"
mapper=$work/root/usr/bin/omarchy-audio-asahi-mic-map
WORK=$work PATH="$work/bin:$PATH" XDG_RUNTIME_DIR="$work/run" XDG_STATE_HOME="$work/state" \
  "$mapper" --watch 2>"$work/log" &
watcher=$!
for _ in $(seq 100); do
  [[ -s $work/subscriber && -f $work/run/omarchy-asahi-mic.reloads ]] && break
  sleep 0.1
done
[[ $(<"$work/run/omarchy-asahi-mic.reloads") == "$watcher" ]] || fail 'the watcher records its PID for the upgrade hook'
subscriber=$(<"$work/subscriber")
printf '#!/bin/bash\necho "$$ $*" >"$WORK/reloaded"\nexec sleep 60\n' >"$work/new"
chmod +x "$work/new"
mv "$work/new" "$mapper"
for _ in $(seq 100); do
  [[ -s $work/reloaded ]] && break
  sleep 0.1
done
[[ $(<"$work/reloaded") == "$watcher --watch" ]] || fail 'the watcher runs its replaced file in place' "$(cat "$work/log")"
! kill -0 "$subscriber" 2>/dev/null || fail 'the old subscriber stops with the old code'
grep -q 'Running the updated microphone mapper' "$work/log" || fail 'the reload is logged'
pass 'a running watcher runs its upgraded program in place within seconds'

# The upgrade hook restarts only mappers that cannot reload themselves: those
# without a matching PID record. Nothing happens in a chroot, an unbooted root,
# off Apple Silicon, or when a user manager does not answer, and the
# transaction never fails.
hook=$work/root/usr/share/libalpm/hooks/90-omarchy-mac-asahi-mic.hook
grep -qx 'Target = usr/bin/omarchy-audio-asahi-mic-map' "$hook" && grep -qx 'Operation = Upgrade' "$hook" &&
  grep -qx 'Exec = /usr/lib/omarchy-mac/asahi-mic-restart' "$hook" || fail 'the hook runs on mapper upgrades'
restart=$work/root/usr/lib/omarchy-mac/asahi-mic-restart
fixture=$work/fixture
mkdir -p "$fixture/run/systemd/system"
socket() { python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
for uid in 1000 1001 1002 1003; do
  mkdir -p "$fixture/run/user/$uid/systemd"
  socket "$fixture/run/user/$uid/systemd/private"
done
mkdir -p "$fixture/run/user/1004"
echo 200 >"$fixture/run/user/1001/omarchy-asahi-mic.reloads"
echo 999 >"$fixture/run/user/1002/omarchy-asahi-mic.reloads"
ln -s "$fixture/run/user/1001/omarchy-asahi-mic.reloads" "$fixture/run/user/1003/omarchy-asahi-mic.reloads"
cat >"$work/bin/id" <<'STUB'
#!/bin/bash
[[ $1 == "-nu" ]] && echo "user$2"
STUB
# MainPIDs: 1000 runs an old mapper, 1001 a self-reloading one, 1002 one that
# replaced a self-reloading one, 1003 an old one beside a linked record, 1004
# has no manager.
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
echo "$*" >>"$WORK/systemctl"
case $2 in
  --machine=user1000@) pid=100 ;;
  --machine=user1001@) pid=200 ;;
  --machine=user1002@) pid=300 ;;
  --machine=user1003@) pid=200 ;;
  *) pid=0 ;;
esac
[[ $3 == "show" ]] && echo "$pid"
[[ -z ${SYSTEMCTL_FAILS:-} ]]
STUB
printf '#!/bin/bash\nexit "${CHROOT:-1}"\n' >"$work/bin/systemd-detect-virt"
chmod +x "$work/bin/"*
hook_run() { WORK=$work PATH="$work/bin:$PATH" OMARCHY_MAC_ROOT=$fixture "$@" "$restart" >/dev/null; }
hook_run env
restarted=$(grep try-restart "$work/systemctl" | sed 's/.*--machine=\([^ ]*\)@.*/\1/' | sort | tr '\n' ' ')
[[ $restarted == "user1000 user1002 user1003 " ]] || fail 'only mappers without a matching PID record restart' "$restarted"
grep -q -- '--user --machine=user1000@ --no-block try-restart omarchy-asahi-mic.service' "$work/systemctl" ||
  fail 'the restart goes through the user manager without blocking pacman'
rm "$work/systemctl"
hook_run env CHROOT=0
[[ ! -e $work/systemctl ]] || fail 'a chroot is left alone'
hook_run env PLATFORM=aarch64
[[ ! -e $work/systemctl ]] || fail 'other machines are left alone'
rm -r "$fixture/run/systemd/system"
hook_run env
[[ ! -e $work/systemctl ]] || fail 'an unbooted root is left alone'
mkdir -p "$fixture/run/systemd/system"
hook_run env SYSTEMCTL_FAILS=1 || fail 'a user manager that fails never fails the transaction'
pass 'the upgrade hook restarts only mappers that predate self-reload'
