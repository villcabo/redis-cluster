# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Infrastructure-as-config (no application code) to deploy a 6-node Redis Cluster (3 masters + 3 replicas) on **Docker Swarm**, plus an optional RedisInsight admin UI gated behind OAuth2 Proxy + Keycloak. Everything is Bash scripts + YAML + config templates.

## Deployment flow (run in order, from a Swarm manager)

```bash
cp .env.example .env            # set NODE_B1/2/3_IP + REDIS_PASSWORD
docker network create -d overlay --attachable redis-net
./01-build-redis-conf.sh        # renders ./conf/redis-{7001..7006}.conf from template (prompts "yes")
docker stack deploy -c redis-stack.yml redis
./02-create-redis-cluster.sh    # idempotent: creates OR repairs cluster (prompts "yes")
./03-test-redis-cluster.sh      # connectivity + health verification (read-only)
```

Optional RedisInsight UI (separate stack/compose, NOT part of the cluster):

```bash
./04-generate-tls-certs.sh      # certs into ./certs for OAuth2 Proxy HTTPS
docker stack deploy -c docker-compose.yml redis-ui   # or docker compose up
```

## Architecture notes that aren't obvious from one file

- **Two independent deployments.** `redis-stack.yml` = the 6 Redis nodes. `docker-compose.yml` = RedisInsight + oauth2-proxy. They share only the external `redis-net` overlay network. Don't conflate them.
- **Node→host pinning is fixed by convention.** Ports map to physical nodes everywhere: `7001/7004 → b1`, `7002/7005 → b2`, `7003/7006 → b3`. Masters are `7001-7003`, replicas `7004-7006`. The `case $port in` blocks in scripts 01/02 encode this — keep them in sync if you add nodes.
- **Swarm placement uses `node.labels.role == b1|b2|b3`** (in `redis-stack.yml`), even though the README prose says nodes are "labeled b1/b2/b3". The actual label key is `role`. Label hosts with `docker node update --label-add role=b1 <node>`.
- **`cluster-announce-*` is what makes Swarm + Redis Cluster work.** The template announces the *host* IP and external port (7001-7006) plus bus port (17001-17006), not the container's internal 6379. This is why clients can follow MOVED redirects across hosts. Bus port = data port + 10000.
- **redis-cli always runs via throwaway containers** (`docker run --rm --network host ... redis:7.4.7-alpine redis-cli`) using `REDISCLI_AUTH` env, never a host-installed binary. Follow this pattern in any new script.

## `02-create-redis-cluster.sh` is a state machine, not a one-shot

It queries the live cluster (`cluster info` + `cluster nodes` from the first reachable node) and branches. Re-running it is safe on a healthy cluster (no-op) and it doubles as the repair tool. The four branches (verified empirically against redis 7.4.7):

- **No node reachable** → create from scratch (masters first, then attach each replica to its paired master by ID).
- **Broken** (`cluster_state=fail` AND (slots < 16384 OR known_nodes < 6)) → `cluster reset hard` on all nodes, then recreate. **Destroys data.** Note: **fresh `cluster-enabled` nodes report `cluster_state:fail` with 0 slots**, so the very first deploy lands here (a harmless reset-then-create), not in the create-from-scratch `else` branch — which is effectively dead code reachable only if a node is reachable yet returns no cluster info.
- **Healthy/degraded** → non-destructive fixes only: demote replicas acting as master (`cluster meet` then `cluster replicate`), promote masters stuck as slave (`cluster failover`), add missing master/replica nodes. Down nodes are skipped, never reset.

Repair edge cases that were tested and fixed (don't reintroduce):
- **Full pair inversion** (designated master is slave AND its replica is master, the normal post-failover state): handled by the failover branch *only*. Do not also queue a demote — `cluster replicate` against a node that is still a slave fails and prints a misleading "Role change may not have completed" warning. The detection at Case 1 excludes this via `master_is_slave == false`.
- **Orphaned node** (e.g. after `CLUSTER RESET`, isolated with `known_nodes:1`): the demote path runs `cluster meet` before `cluster replicate`, otherwise the isolated node rejects the unknown target ID.

## Conventions

- All four scripts share the same `log_info/success/error/warning` tput-color helpers and the same `.env` loader. The loader differs by design: script 01 uses `. ./.env` (sourcing); scripts 02/03 parse with `grep | sed` to strip quotes/comments. Match the destructive-vs-readonly intent when editing.
- Scripts that mutate state (01, 02) print a PREVIEW block and require typing `yes`. Preserve this guard on any new mutating script.
- The image tag `redis:7.4.7-alpine` is hardcoded across scripts and `redis-stack.yml`. Bump all occurrences together.
- Generated `./conf/` and `.env` are gitignored. `redis-cluster.tmpl` is the source of truth for node config; `envsubst` fills `NODE_IP`, `REDIS_PASSWORD`, `EXTERNAL_PORT`, `EXTERNAL_BUS_PORT`, `INTERNAL_PORT`.

## Gotchas

- `stat -f%z` (BSD) vs `stat -c%s` (GNU) is handled with a fallback in script 01 — don't "simplify" it to one form.
- `requirepass` + `masterauth` are both set to `REDIS_PASSWORD`; replicas need `masterauth` to sync. Changing the password means re-rendering all confs and redeploying.
- README's Spring Boot section is for *consumers* of this cluster, not part of the deploy.
