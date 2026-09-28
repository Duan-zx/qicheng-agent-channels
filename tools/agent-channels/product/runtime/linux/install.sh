#!/bin/sh
set -eu
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${XDG_DATA_HOME:-"$HOME/.local/share"}/qicheng-lite
token_file=
broker_token_file=
start_after=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) prefix=$2; shift 2 ;;
    --token-file) token_file=$2; shift 2 ;;
    --broker-token-file) broker_token_file=$2; shift 2 ;;
    --start) start_after=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$prefix" in /*) ;; *) echo '--prefix must be absolute.' >&2; exit 2;; esac
[ "$prefix" != "$src" ] || { echo 'Install prefix must differ from the extracted package.' >&2; exit 2; }
parent=$(dirname -- "$prefix")
mkdir -p "$parent"
stage="$parent/.qicheng-lite-stage-$$"
backup="$parent/.qicheng-lite-backup-$$"
rm -rf "$stage"
mkdir -p "$stage"
cp -a "$src/." "$stage/"
chmod 755 "$stage/install.sh" "$stage/start-qicheng-lite.sh" "$stage/diagnose-qicheng-lite.sh"
mkdir -p "$stage/.local"
if [ -n "$token_file" ]; then
  [ -f "$token_file" ] || { echo 'Token file does not exist.' >&2; rm -rf "$stage"; exit 2; }
  token=$(tr -d '\r\n' < "$token_file")
elif [ -f "$prefix/.local/channel.token" ]; then
  token=$(tr -d '\r\n' < "$prefix/.local/channel.token")
else
  token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
fi
case "$token" in *[!0-9a-f]*|'') echo 'Token must be 64 lowercase hexadecimal characters.' >&2; rm -rf "$stage"; exit 2;; esac
[ "${#token}" -eq 64 ] || { echo 'Token must be 64 lowercase hexadecimal characters.' >&2; rm -rf "$stage"; exit 2; }
printf '%s' "$token" > "$stage/.local/channel.token"
if [ -n "$broker_token_file" ]; then
  [ -f "$broker_token_file" ] || { echo 'Broker token file does not exist.' >&2; rm -rf "$stage"; exit 2; }
  broker_token=$(tr -d '\r\n' < "$broker_token_file")
elif [ -f "$prefix/.local/broker.token" ]; then
  broker_token=$(tr -d '\r\n' < "$prefix/.local/broker.token")
else
  broker_token=
fi
if [ -n "$broker_token" ]; then
  case "$broker_token" in *[!0-9a-f]*|'') echo 'Broker token must be 64 lowercase hexadecimal characters.' >&2; rm -rf "$stage"; exit 2;; esac
  [ "${#broker_token}" -eq 64 ] && [ "$broker_token" != "$token" ] || { echo 'Broker token invalid or identical to channel token.' >&2; rm -rf "$stage"; exit 2; }
  printf '%s' "$broker_token" > "$stage/.local/broker.token"
  chmod 600 "$stage/.local/broker.token"
  if [ -f "$prefix/.local/viewer.token" ]; then
    viewer_token=$(tr -d '\r\n' < "$prefix/.local/viewer.token")
  else
    viewer_token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  fi
  case "$viewer_token" in *[!0-9a-f]*|'') echo 'Viewer token must be 64 lowercase hexadecimal characters.' >&2; rm -rf "$stage"; exit 2;; esac
  [ "${#viewer_token}" -eq 64 ] && [ "$viewer_token" != "$token" ] && [ "$viewer_token" != "$broker_token" ] || { echo 'Viewer token invalid or identical to another token.' >&2; rm -rf "$stage"; exit 2; }
  printf '%s' "$viewer_token" > "$stage/.local/viewer.token"
  chmod 600 "$stage/.local/viewer.token"
fi
chmod 700 "$stage/.local"
chmod 600 "$stage/.local/channel.token"
if [ -e "$prefix" ]; then mv "$prefix" "$backup"; fi
if ! mv "$stage" "$prefix"; then
  [ ! -e "$backup" ] || mv "$backup" "$prefix"
  exit 1
fi
rm -rf "$backup"
printf '%s\n' "Installed Qicheng Lite to $prefix"
if [ "$start_after" -eq 1 ]; then exec "$prefix/start-qicheng-lite.sh" --build --background; fi
