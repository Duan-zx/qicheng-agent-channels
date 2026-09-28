#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build=0
background=0
while [ "$#" -gt 0 ]; do
  case "$1" in --build) build=1;; --background) background=1;; *) echo "Unknown argument: $1" >&2; exit 2;; esac
  shift
done
[ -f "$root/.local/channel.token" ] || { echo 'Missing .local/channel.token; rerun install.sh.' >&2; exit 2; }
channel_token=$(tr -d '\r\n' < "$root/.local/channel.token")
case "$channel_token" in *[!a-f0-9]*|'') echo 'Invalid channel token.' >&2; exit 2;; esac
[ "${#channel_token}" -eq 64 ] || { echo 'Invalid channel token.' >&2; exit 2; }
broker_enabled=0
if [ -f "$root/.local/broker.token" ]; then
  broker_enabled=1
  [ -f "$root/compose.broker.yaml" ] || { echo 'Missing broker compose override.' >&2; exit 2; }
  [ -f "$root/.local/viewer.token" ] || { echo 'Missing viewer token in broker mode.' >&2; exit 2; }
  broker_token=$(tr -d '\r\n' < "$root/.local/broker.token")
  viewer_token=$(tr -d '\r\n' < "$root/.local/viewer.token")
  case "$broker_token" in *[!a-f0-9]*|'') echo 'Invalid broker token.' >&2; exit 2;; esac
  case "$viewer_token" in *[!a-f0-9]*|'') echo 'Invalid viewer token.' >&2; exit 2;; esac
  [ "${#broker_token}" -eq 64 ] && [ "$broker_token" != "$channel_token" ] || { echo 'Invalid broker token.' >&2; exit 2; }
  [ "${#viewer_token}" -eq 64 ] && [ "$viewer_token" != "$channel_token" ] && [ "$viewer_token" != "$broker_token" ] || { echo 'Invalid viewer token.' >&2; exit 2; }
fi
command -v curl >/dev/null 2>&1 || { echo 'curl is required for authenticated backend health checks.' >&2; exit 3; }
if command -v python3 >/dev/null 2>&1; then json_python=python3
elif command -v python >/dev/null 2>&1; then json_python=python
else echo 'Python is required for backend state validation.' >&2; exit 3; fi
if [ "$broker_enabled" -eq 1 ]; then expected_mode=broker; else expected_mode=direct; fi
docker version --format '{{.Server.Version}}' >/dev/null || { echo 'Docker Linux engine is unavailable. Qicheng Lite does not bundle Docker Desktop.' >&2; exit 3; }
set -- docker compose --project-name qicheng-agent-channels --project-directory "$root" -f "$root/compose.yaml"
if [ "$broker_enabled" -eq 1 ]; then set -- "$@" -f "$root/compose.broker.yaml"; fi
stop_channels() {
  if [ "$broker_enabled" -eq 1 ]; then
    docker compose --project-name qicheng-agent-channels --project-directory "$root" -f "$root/compose.yaml" -f "$root/compose.broker.yaml" stop channel1 channel2
  fi
}
set -- "$@" --profile second up -d
if [ "$build" -eq 1 ]; then set -- "$@" --build; else set -- "$@" --no-build; fi
if ! "$@" channel1 channel2; then
  stop_channels >/dev/null 2>&1 || echo 'Failed to stop broker channels after startup error; stop them manually.' >&2
  echo 'Backend startup failed; viewer not started.' >&2
  exit 4
fi
check_state() {
  port=$1
  state=$(printf 'header = "Authorization: Bearer %s"\n' "$channel_token" | curl --noproxy '*' --max-time 2 --silent --fail --config - "http://127.0.0.1:$port/api/state") || return 1
  printf '%s' "$state" | "$json_python" -c '
import json,sys
try:
    state=json.load(sys.stdin)
    valid=(state.get("input_target")=="private-linux-display"
           and int(state.get("width",0))>0 and int(state.get("height",0))>0)
    if sys.argv[1]=="broker":
        valid=(valid and state.get("input_auth")=="broker-v2"
               and str(state.get("channel_id"))==str(int(sys.argv[2])-18760))
    sys.exit(0 if valid else 1)
except (ValueError,TypeError,AttributeError):
    sys.exit(1)
' "$expected_mode" "$port" >/dev/null 2>&1
}
attempt=0
ready1=0
ready2=0
while [ "$attempt" -lt 45 ]; do
  if [ "$ready1" -eq 0 ] && check_state 18761; then ready1=1; fi
  if [ "$ready2" -eq 0 ] && check_state 18762; then ready2=1; fi
  if [ "$ready1" -eq 1 ] && [ "$ready2" -eq 1 ]; then break; fi
  attempt=$((attempt + 1))
  sleep 0.5
done
if [ "$ready1" -ne 1 ] || [ "$ready2" -ne 1 ]; then
  if ! stop_channels >/dev/null 2>&1; then echo 'Failed to stop broker channels; stop them manually.' >&2; fi
  echo 'Backend state check failed for 18761/18762. Broker mode requires input_auth=broker-v2; rebuild an old image with --build. Viewer not started.' >&2
  exit 4
fi
viewer="$root/dist-linux/AgentChannels"
if [ -x "$viewer" ]; then
  if [ "$background" -eq 1 ]; then "$viewer" --background >/dev/null 2>&1 & else "$viewer" >/dev/null 2>&1 & fi
  printf '%s\n' 'Qicheng Lite backend and viewer started.'
else
  printf '%s\n' 'Qicheng Lite backend started; this package has no compatible Linux viewer binary.'
fi
