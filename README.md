# Redis with Docker Compose

*[Español](README.es.md)*

Run Redis three ways from a single `docker-compose.yml` using profiles:
**standalone**, **cluster on one machine**, and **cluster spread across several servers**.
Optionally RedisInsight, on its own or protected with OAuth2 + Keycloak.

> High availability comes from Redis Cluster itself (replication + automatic
> failover), not the orchestrator. That's why Swarm isn't needed: each server runs
> its own `docker compose` and the nodes talk to each other over IP:port.

## Clone

```bash
git clone https://github.com/villcabo/redis-cluster.git   # HTTPS
git clone git@github.com:villcabo/redis-cluster.git       # SSH
cd redis-cluster
```

## Getting started

```bash
cp .env.example .env      # set REDIS_PASSWORD (and ANNOUNCE_IP for multi-host)
# or: ./scripts/env-sync.sh   # create/update .env from .env.example, keeping your values
```

The profile is set in `.env` via `COMPOSE_PROFILES`, so you just run `docker compose up -d`.
You can also pass it by hand with `--profile` (overrides the `.env` value).

| I want | `COMPOSE_PROFILES` in `.env` | or by hand |
|---|---|---|
| Plain Redis with a password | `standalone` | `docker compose --profile standalone up -d` |
| Cluster on a single machine | `cluster` | `docker compose --profile cluster up -d` |
| + RedisInsight (UI) | `cluster,insight` | `--profile cluster --profile insight` |
| RedisInsight protected (OAuth2) | `insight-oauth` | `--profile insight-oauth` |

With the profile in `.env`: `docker compose up -d` (cluster → then `./scripts/cluster-init.sh`).

Ports: standalone `6379`; cluster `7001-7006` (bus `17001-17006`); UI `5540`; oauth2 `4180`.

## Cluster on a single machine (single-host)

```bash
# .env -> ANNOUNCE_IP=<host LAN IP>   (NOT 127.0.0.1, see note below)
docker compose --profile cluster up -d
./scripts/cluster-init.sh     # forms the cluster (once)
./scripts/cluster-check.sh    # verify
```

> **Don't use `127.0.0.1` for `ANNOUNCE_IP`.** With a bridge network each container
> has its own loopback, so node-to-node gossip over `127.0.0.1` never crosses and the
> cluster never forms. Use the host's LAN IP (`ip -4 route get 1.1.1.1`).

## Cluster across several servers (multi-host)

3 servers, 2 nodes each. Each master's replica lands on a different server → HA.

1. On **each** server, set `.env` with its own public IP:
   ```ini
   ANNOUNCE_IP=10.0.0.1        # 10.0.0.2 on server 2, 10.0.0.3 on server 3
   ```
2. Bring up the 2 nodes assigned to each server:
   ```bash
   # server 1            server 2            server 3
   docker compose --profile node1 up -d   # node2 / node3 respectively
   ```
3. Form the cluster **once** from any server. In its `.env`:
   ```ini
   NODES="10.0.0.1:7001 10.0.0.2:7002 10.0.0.3:7003 10.0.0.1:7004 10.0.0.2:7005 10.0.0.3:7006"
   ```
   ```bash
   ./scripts/cluster-init.sh
   ```

Ports `7001-7006` and bus `17001-17006` must be open between servers (firewall).

## RedisInsight protected with OAuth2 + Keycloak

```bash
# 1. edit oauth2/oauth2-proxy-keycloak.cfg (client_id, secret, issuer, cookie_secret)
# 2. (optional HTTPS) ./scripts/generate-tls-certs.sh
# 3. in .env: INSIGHT_BIND=127.0.0.1   # so the UI is only reachable through the proxy
docker compose --profile insight-oauth up -d
```
Access at `http(s)://<server>:4180`. Without oauth, use `--profile insight` and open `:5540`.

## Operations

```bash
./scripts/cluster-check.sh        # cluster status
./scripts/cluster-check.sh fix    # repair slots (--cluster fix)
docker compose --profile cluster down            # stop (keeps data)
docker compose --profile cluster down -v         # stop and DELETE data
```

## Notes

- Pinned image `redis:8.6.3-alpine`. Config is passed via command-line in `docker-compose.yml` (no `.conf` files).
- Data lives in named volumes (`redisN-data`). To pin it to a disk, swap the `volumes:` for bind mounts.
- Changing the password = `docker compose ... up -d --force-recreate` after editing `.env`.
- Resource limits and `maxmemory`/policy are set in `.env` (Resources section). Defaults
  are sized for testing; in prod, size `REDIS_MAXMEMORY` to ~75% of `NODE_MEM_LIMIT` and
  keep the sum of all nodes' maxmemory under physical RAM (leave headroom for BGSAVE/AOF fork).
