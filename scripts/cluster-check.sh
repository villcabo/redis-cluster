#!/usr/bin/env bash
# Chequeo de salud del cluster (read-only).
#   ./scripts/cluster-check.sh        -> check + cluster nodes
#   ./scripts/cluster-check.sh fix    -> intenta reparar slots (--cluster fix)
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="redis:8.6.3-alpine"

[ -f .env ] || { echo "ERROR: falta .env (cp .env.example .env)"; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a
: "${REDIS_PASSWORD:?REDIS_PASSWORD no definido en .env}"

# Primer nodo del cluster: de NODES si está, si no 127.0.0.1:7001
ENTRY="${NODES:-}"; ENTRY="${ENTRY%% *}"; ENTRY="${ENTRY:-127.0.0.1:7001}"

cli() { docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" "$IMAGE" redis-cli "$@"; }

if [ "${1:-}" = "fix" ]; then
  cli --cluster fix "$ENTRY"
  exit 0
fi

echo "== cluster check ($ENTRY) =="
cli --cluster check "$ENTRY" || echo "(check reportó problemas)"
echo
echo "== cluster nodes =="
HOST="${ENTRY%%:*}"; PORT="${ENTRY##*:}"
cli -h "$HOST" -p "$PORT" cluster nodes
