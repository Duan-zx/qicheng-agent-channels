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
docker version --format '{{.Server.Version}}' >/dev/null || { echo 'Docker Linux engine is unavailable. Qicheng Lite does not bundle Docker Desktop.' >&2; exit 3; }
set -- docker compose --project-name qicheng-agent-channels --project-directory "$root" -f "$root/compose.yaml" --profile second up -d
if [ "$build" -eq 1 ]; then set -- "$@" --build; else set -- "$@" --no-build; fi
"$@" channel1 channel2
viewer="$root/dist-linux/AgentChannels"
if [ -x "$viewer" ]; then
  if [ "$background" -eq 1 ]; then "$viewer" --background >/dev/null 2>&1 & else "$viewer" >/dev/null 2>&1 & fi
  printf '%s\n' 'Qicheng Lite backend and viewer started.'
else
  printf '%s\n' 'Qicheng Lite backend started; this package has no compatible Linux viewer binary.'
fi
