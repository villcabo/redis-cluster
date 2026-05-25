# Redis con Docker Compose

*[English](README.md)*

Levanta Redis en tres formas con un solo `docker-compose.yml` y profiles:
**standalone**, **cluster en una máquina** y **cluster repartido en varios servers**.
Opcionalmente RedisInsight, sola o protegida con OAuth2 + Keycloak.

> La alta disponibilidad la da Redis Cluster (replicación + failover automático),
> no el orquestador. Por eso no hace falta Swarm: cada server corre su propio
> `docker compose` y los nodos se hablan por IP:puerto.

## Antes de empezar

```bash
cp .env.example .env      # poné REDIS_PASSWORD (y ANNOUNCE_IP si es multi-host)
```

El profile se fija en `.env` con `COMPOSE_PROFILES`, así corrés solo `docker compose up -d`.
También podés pasarlo a mano con `--profile` (pisa lo del `.env`).

| Quiero | `COMPOSE_PROFILES` en `.env` | o a mano |
|---|---|---|
| Redis suelto con password | `standalone` | `docker compose --profile standalone up -d` |
| Cluster en una sola máquina | `cluster` | `docker compose --profile cluster up -d` |
| + RedisInsight (UI) | `cluster,insight` | `--profile cluster --profile insight` |
| RedisInsight protegida (OAuth2) | `insight-oauth` | `--profile insight-oauth` |

Con el profile en `.env`: `docker compose up -d` (cluster → luego `./scripts/cluster-init.sh`).

Puertos: standalone `6379`; cluster `7001-7006` (bus `17001-17006`); UI `5540`; oauth2 `4180`.

## Cluster en una máquina (single-host)

```bash
# .env -> ANNOUNCE_IP=<IP LAN del host>   (NO 127.0.0.1, ver nota abajo)
docker compose --profile cluster up -d
./scripts/cluster-init.sh     # forma el cluster (una vez)
./scripts/cluster-check.sh    # verifica
```

> **No uses `127.0.0.1` en `ANNOUNCE_IP`.** Con red bridge cada contenedor tiene
> su propio loopback, así que el gossip entre nodos por `127.0.0.1` no cruza y el
> cluster nunca se forma. Usá la IP LAN del host (`ip -4 route get 1.1.1.1`).

## Cluster en varios servers (multi-host)

3 servers, 2 nodos cada uno. La replica de cada master queda en otro server → HA.

1. En **cada** server, `.env` con su propia IP pública:
   ```ini
   ANNOUNCE_IP=10.0.0.1        # 10.0.0.2 en el server 2, 10.0.0.3 en el 3
   ```
2. Levantar los 2 nodos que le tocan a cada server:
   ```bash
   # server 1            server 2            server 3
   docker compose --profile node1 up -d   # node2 / node3 respectivamente
   ```
3. Formar el cluster **una vez** desde cualquier server. En su `.env`:
   ```ini
   NODES="10.0.0.1:7001 10.0.0.2:7002 10.0.0.3:7003 10.0.0.1:7004 10.0.0.2:7005 10.0.0.3:7006"
   ```
   ```bash
   ./scripts/cluster-init.sh
   ```

Los puertos `7001-7006` y bus `17001-17006` deben estar abiertos entre servers (firewall).

## RedisInsight protegida con OAuth2 + Keycloak

```bash
# 1. editar oauth2/oauth2-proxy-keycloak.cfg (client_id, secret, issuer, cookie_secret)
# 2. (opcional HTTPS) ./scripts/generate-tls-certs.sh
# 3. en .env: INSIGHT_BIND=127.0.0.1   # que la UI solo salga por el proxy
docker compose --profile insight-oauth up -d
```
Acceso por `http(s)://<server>:4180`. Sin oauth, usá `--profile insight` y entrá a `:5540`.

## Operación

```bash
./scripts/cluster-check.sh        # estado del cluster
./scripts/cluster-check.sh fix    # reparar slots (--cluster fix)
docker compose --profile cluster down            # parar (conserva datos)
docker compose --profile cluster down -v         # parar y BORRAR datos
```

## Notas

- Imagen fija `redis:8.6.3-alpine`. La config va por command-line en `docker-compose.yml` (sin archivos `.conf`).
- Datos en volúmenes nombrados (`redisN-data`). Para anclar a disco, cambiá los `volumes:` por bind mounts.
- Cambiar el password = `docker compose ... up -d --force-recreate` tras editar `.env`.
