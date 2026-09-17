#!/bin/sh
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
failed=0
check_file(){ if [ -f "$2" ]; then printf 'PASS %-24s %s\n' "$1" "$2"; else printf 'FAIL %-24s %s\n' "$1" "$2"; failed=$((failed+1)); fi; }
check_file token "$root/.local/channel.token"
check_file compose "$root/compose.yaml"
check_file dockerfile "$root/Dockerfile"
check_file license "$root/LICENSE"
if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  printf 'PASS %-24s %s\n' docker-linux-engine available
  docker compose --project-name qicheng-agent-channels --project-directory "$root" -f "$root/compose.yaml" --profile second ps || failed=$((failed+1))
else
  printf 'FAIL %-24s %s\n' docker-linux-engine unavailable
  failed=$((failed+1))
fi
for port in 18761 18762; do
  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 "http://127.0.0.1:$port/health" >/dev/null; then
    printf 'PASS channel-health           127.0.0.1:%s\n' "$port"
  else
    printf 'FAIL channel-health           127.0.0.1:%s\n' "$port"
    failed=$((failed+1))
  fi
done
printf 'Volumes are never removed by these scripts.\n'
exit "$failed"
