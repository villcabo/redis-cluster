#!/usr/bin/env bash
# Forma el cluster Redis. Correr UNA sola vez, después de levantar los nodos.
#   single-host -> usa 127.0.0.1:7001..7006 por defecto
#   multi-host  -> definí NODES en .env con las 6 IP:puerto reales
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="redis:8.6.3-alpine"

[ -f .env ] || { echo "ERROR: falta .env (cp .env.example .env)"; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a
: "${REDIS_PASSWORD:?REDIS_PASSWORD no definido en .env}"

# Si no se define NODES (single-host), se arma con ANNOUNCE_IP y los 6 puertos.
# Nunca 127.0.0.1: con bridge network el gossip por loopback no cruza contenedores.
NODES="${NODES:-}"
if [ -z "$NODES" ]; then
  ip="${ANNOUNCE_IP:?ANNOUNCE_IP no definido en .env}"
  NODES="$ip:7001 $ip:7002 $ip:7003 $ip:7004 $ip:7005 $ip:7006"
fi

echo "================ PREVIEW ================"
echo "Crear cluster con --cluster-replicas 1 sobre:"
for n in $NODES; do echo "  - $n"; done
echo "Los primeros 3 serán masters, el resto replicas."
echo "========================================"
read -r -p 'Escribí "yes" para continuar: ' ans
[ "$ans" = "yes" ] || { echo "Cancelado."; exit 1; }

# shellcheck disable=SC2086
docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" "$IMAGE" \
  redis-cli --cluster create $NODES --cluster-replicas 1 --cluster-yes

echo "Listo. Verificá con: ./scripts/cluster-check.sh"
