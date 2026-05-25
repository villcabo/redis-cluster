# CLAUDE.md

Guía para Claude Code al trabajar en este repo.

## Qué es

Infra-as-config (sin código de aplicación) para levantar Redis con Docker Compose en
tres modos —standalone, cluster single-host y cluster multi-host— más RedisInsight
opcional protegida con OAuth2 Proxy + Keycloak. Todo es un `docker-compose.yml` con profiles
+ scripts Bash. **No usa Docker Swarm** (decisión deliberada, ver abajo).

## Por qué Compose y no Swarm

La HA de Redis Cluster (replicación + failover) la da Redis mismo a nivel de protocolo
gossip, no el orquestador. Redis solo necesita que cada nodo alcance a los demás por
`IP:puerto`. Para 3 nodos fijos, Swarm solo aportaba despliegue centralizado a costa de
labels/placement/overlay/quorum —y encima había que usar placement constraints para
*pelear* contra el scheduler y fijar cada nodo a su host. Multi-host se hace corriendo
`docker compose` en cada server con su `ANNOUNCE_IP`.

## Diseño

- **Un solo `docker-compose.yml`, profiles para elegir modo**: `standalone`, `cluster`
  (los 6 nodos en una máquina), `node1|node2|node3` (2 nodos por server, multi-host),
  `insight`, `insight-oauth`. Cada nodo de cluster vive en su profile single-host
  (`cluster`) **y** su profile por-host (`nodeN`) a la vez.
- **Config por command-line, no archivos `.conf`.** El `command:` usa `sh -c` con
  `$$VAR` (el `$$` = `$` literal que expande el shell del contenedor con sus env vars:
  `REDIS_PORT`, `BUS_PORT`, `ANNOUNCE_IP`, `REDIS_PASSWORD`). Anchor `&redis-cluster`
  comparte image/command/healthcheck; cada servicio solo define puerto y volumen.
- **Pinning puerto↔nodo**: masters `7001-7003`, replicas `7004-7006`, bus = puerto+10000.
  `redis1/4→node1`, `redis2/5→node2`, `redis3/6→node3`.

## Gotcha crítico: ANNOUNCE_IP nunca es 127.0.0.1

Con red bridge cada contenedor tiene su loopback aislado. Si un nodo anuncia
`127.0.0.1:bus`, los demás contenedores resuelven ese `127.0.0.1` a *sí mismos* y el
handshake gossip falla → el cluster nunca se forma (`cluster_known_nodes:1`, queda un
`set-config-epoch` suelto en el log). **Verificado empíricamente con 7.4.7 y 8.6.3.** Hay
que anunciar una IP real del host (LAN). Single-host y multi-host: misma regla.

En **Redis 8.x** el cluster tarda ~10s en converger a `cluster_state:ok` tras el
`--cluster create` (en 7.4.7 era inmediato): un `cluster-check.sh` corrido de inmediato
puede ver `fail`/`CLUSTERDOWN` transitorio. Esperar unos segundos y reintentar.

## Scripts (`scripts/`)

- `cluster-init.sh` — forma el cluster una vez con `redis-cli --cluster create
  ... --cluster-replicas 1 --cluster-yes`. Single-host arma `NODES` desde `ANNOUNCE_IP`;
  multi-host lee `NODES` del `.env`. Imprime PREVIEW y pide `yes`.
- `cluster-check.sh` — read-only (`--cluster check` + `cluster nodes`); `fix` corre
  `--cluster fix`. Reemplazó la máquina de estados de ~700 líneas del repo viejo: la
  reparación ahora es nativa de redis-cli.
- `generate-tls-certs.sh` — cert self-signed para HTTPS de oauth2-proxy (CN = ANNOUNCE_IP).

## Convenciones

- `redis-cli` siempre vía contenedor descartable: `docker run --rm --network host
  -e REDISCLI_AUTH=... redis:8.6.3-alpine redis-cli ...`. Nunca binario del host.
- Imagen `redis:8.6.3-alpine` fija; bumpear en `docker-compose.yml` y en los scripts juntos.
- Scripts que mutan estado (`cluster-init.sh`) imprimen PREVIEW y exigen `yes`.
- `.env` y `certs/*.{crt,key}` y `oauth2/*config.cfg` propios están gitignored.
- `INSIGHT_BIND=127.0.0.1` en modo `insight-oauth` para no exponer la UI directa.
- La sección Spring Boot del README (si vuelve) sería para *consumidores*, no parte del deploy.
