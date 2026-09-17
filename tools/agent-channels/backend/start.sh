#!/bin/sh
set -eu
export DISPLAY=:99 HOME="${QICHENG_HOME:-/home/channel}" LANG=C.UTF-8
browser_pid=""
server_pid=""
maximizer_pid=""
openbox_pid=""
xvfb_pid=""
shutting_down=0

signal_process() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null && kill -TERM "$1" 2>/dev/null || true
}

wait_for_process() {
  pid="$1"
  ticks="${2:-40}"
  [ -n "$pid" ] || return 0
  count=0
  while kill -0 "$pid" 2>/dev/null && [ "$count" -lt "$ticks" ]; do
    count=$((count + 1))
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
  wait "$pid" 2>/dev/null || true
}

shutdown_children() {
  [ "$shutting_down" -eq 0 ] || return 0
  shutting_down=1
  # Keep X11 alive while Firefox handles TERM and flushes its persistent profile.
  signal_process "$browser_pid"
  signal_process "$server_pid"
  wait_for_process "$browser_pid" "${QICHENG_STOP_TICKS:-40}"
  wait_for_process "$server_pid" "${QICHENG_STOP_TICKS:-40}"
  signal_process "$maximizer_pid"
  signal_process "$openbox_pid"
  signal_process "$xvfb_pid"
  wait_for_process "$maximizer_pid" 10
  wait_for_process "$openbox_pid" 10
  wait_for_process "$xvfb_pid" 10
}

handle_signal() {
  status="$1"
  trap - TERM INT
  shutdown_children
  exit "$status"
}

trap 'handle_signal 143' TERM
trap 'handle_signal 130' INT
mkdir -p "$HOME" /tmp/.X11-unix
Xvfb :99 -screen 0 "${SCREEN_WIDTH:-1600}x${SCREEN_HEIGHT:-900}x24" -nolisten tcp -ac &
xvfb_pid=$!
count=0
until xdpyinfo -display :99 >/dev/null 2>&1; do
  count=$((count + 1))
  [ "$count" -lt 50 ] || exit 1
  sleep 0.1
done
openbox >/dev/null 2>&1 &
openbox_pid=$!
xsetroot -solid '#142235'
export DBUS_SESSION_BUS_ADDRESS="$(dbus-daemon --session --fork --print-address)"
printf '%s' "$DBUS_SESSION_BUS_ADDRESS" > /tmp/qicheng-dbus-address
mkdir -p "$HOME/.mozilla" "$HOME/Downloads"
# Let Firefox use profiles.ini/default profile so migrated browser state remains usable.
firefox-esr --new-instance "file:///app/welcome.html#${CHANNEL_ID:-1}" >/tmp/browser.log 2>&1 &
browser_pid=$!
(
  count=0
  window_id=""
  while [ "$count" -lt 100 ]; do
    window_id="$(xdotool search --onlyvisible --pid "$browser_pid" 2>/dev/null | head -n 1 || true)"
    [ -n "$window_id" ] || window_id="$(xdotool search --onlyvisible --class firefox 2>/dev/null | head -n 1 || true)"
    [ -n "$window_id" ] && break
    count=$((count + 1))
    sleep 0.1
  done
  if [ -n "$window_id" ]; then
    window_hex="$(printf '0x%x' "$window_id")"
    wmctrl -i -r "$window_hex" -b add,maximized_vert,maximized_horz || true
  fi
) &
maximizer_pid=$!
python3 /app/server.py &
server_pid=$!
server_status=0
wait "$server_pid" || server_status=$?
shutdown_children
exit "$server_status"
