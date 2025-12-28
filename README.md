# Redis Cluster DevOps Setup

Complete Redis cluster deployment with 6 nodes (3 masters + 3 replicas) using Docker Swarm.

## Architecture

- **6 Redis nodes**: Ports 7001-7006 (data) + 17001-17006 (cluster bus)
- **3 Masters**: redis1, redis2, redis3
- **3 Replicas**: redis4, redis5, redis6
- **Distribution**: 2 containers per physical node (1 master + 1 replica)
- **High Availability**: Automatic failover and data sharding

## Prerequisites

- Docker Swarm cluster with 3 nodes labeled as `b1`, `b2`, `b3`
- Network overlay `redis-net` created
- Redis 7.4.7-alpine image

## Step 1: Environment Configuration

Copy and customize the environment file:

```bash
cp .env.example .env
```

Edit `.env` with your specific values:
- **NODE_B1_IP**: IP address of physical node b1 (runs redis1, redis4)
- **NODE_B2_IP**: IP address of physical node b2 (runs redis2, redis5)
- **NODE_B3_IP**: IP address of physical node b3 (runs redis3, redis6)
- **REDIS_PASSWORD**: Secure password (use provided generation commands)

Generate a secure password:

```bash
openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
```

## Step 2: Docker Swarm Network

Create overlay network for Redis cluster:

```bash
docker network create -d overlay --attachable redis-net
```

Or with custom MTU:

```bash
docker network create -d overlay --attachable --opt com.docker.network.driver.mtu=1450 redis-net
```

## Step 3: Directory Preparation

### Node b1 (Master + Replica)

```bash
sudo mkdir -p /opt/redis/data/node1 /opt/redis/data/node4
sudo chown -R 999:999 /opt/redis/data
```

### Node b2 (Master + Replica)

```bash
sudo mkdir -p /opt/redis/data/node2 /opt/redis/data/node5
sudo chown -R 999:999 /opt/redis/data
```

### Node b3 (Master + Replica)

```bash
sudo mkdir -p /opt/redis/data/node3 /opt/redis/data/node6
sudo chown -R 999:999 /opt/redis/data
```

## Step 4: Generate Redis Configurations

Build Redis configuration files for all nodes:

```bash
./01-build-redis-conf.sh
```

This creates `./conf/redis-{port}.conf` files for each Redis instance.

## Step 5: Deploy Redis Stack

Deploy the Redis cluster services:

```bash
docker stack deploy -c redis-stack.yml redis
```

## Step 6: Verify Services

Check service status:

```bash
docker stack services redis
```

Monitor service deployment:

```bash
docker service ps redis_redis1
docker service ps redis_redis2
docker service ps redis_redis3
docker service ps redis_redis4
docker service ps redis_redis5
docker service ps redis_redis6
```

## Step 7: Initialize Redis Cluster

Create the Redis cluster configuration:

```bash
./02-create-redis-cluster.sh
```

This command:
- Tests connectivity to all nodes
- Creates cluster with 3 masters and 3 replicas
- Verifies cluster status

## Step 8: Verification

### Automated Cluster Testing

Run comprehensive cluster tests:

```bash
./03-test-redis-cluster.sh
```

This script performs:
- **Connectivity tests**: Verifies all 6 nodes are accessible
- **Cluster status check**: Shows cluster health and slot distribution
- **Node information**: Displays master/replica relationships
- **Basic operations**: Tests SET/GET operations with cluster redirections
- **Resilient reporting**: Continues testing even if some nodes are down
- **Detailed summary**: Shows available/failed nodes with recommendations

**Sample output:**
```
[INFO] Connectivity Summary:
  - Available nodes: 6/6
  - Failed nodes: 0/6

[SUCCESS] Redis cluster is working perfectly!

[INFO] Cluster summary:
  - Status: Healthy and operational
  - Available nodes: 6/6
  - Authentication: Secured
  - Basic operations: Working
```

### Manual Cluster Verification

### Check Cluster Status

```bash
redis-cli -h <node-b1-ip> -p 7001 -a <your-password> cluster nodes
```

### Test Cluster Operations

```bash
redis-cli -h <node-b1-ip> -p 7001 -a <your-password> set key1 "value1"
redis-cli -h <node-b2-ip> -p 7002 -a <your-password> get key1
```

### Check Service Logs

```bash
docker service logs -f redis_redis1
docker service logs -f redis_redis2
docker service logs -f redis_redis3
docker service logs -f redis_redis4
docker service logs -f redis_redis5
docker service logs -f redis_redis6
```

## Spring Boot Configuration

For your Spring Boot applications, use this cluster configuration:

```yaml
spring:
  data:
    redis:
      cluster:
        nodes:
          - ${NODE_B1_IP}:7001  # redis1 (master)
          - ${NODE_B2_IP}:7002  # redis2 (master)
          - ${NODE_B3_IP}:7003  # redis3 (master)
          - ${NODE_B1_IP}:7004  # redis4 (replica)
          - ${NODE_B2_IP}:7005  # redis5 (replica)
          - ${NODE_B3_IP}:7006  # redis6 (replica)
        max-redirects: 3
      password: ${REDIS_PASSWORD}
      timeout: 3000ms
      lettuce:
        cluster:
          refresh:
            adaptive: true
            period: 30s
```

**Alternative minimal configuration (masters only):**

```yaml
spring:
  data:
    redis:
      cluster:
        nodes:
          - ${NODE_B1_IP}:7001  # redis1
          - ${NODE_B2_IP}:7002  # redis2
          - ${NODE_B3_IP}:7003  # redis3
        max-redirects: 3
      password: ${REDIS_PASSWORD}
```

## Maintenance Commands

### Update Services

```bash
docker service update --image redis:7.4.7-alpine redis_redis1
```

### Remove Stack

```bash
docker stack rm redis
```

### Manual Role Management

Use these commands to manually manage node roles in the Redis cluster.

#### Check Current Roles

```bash
# View all nodes and their roles (master/slave)
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <node-ip> -p 7001 cluster nodes

# Output format: <node-id> <ip:port> <flags> <master-id> <ping> <pong> <config-epoch> <link-state> <slot>
# flags: master, slave, myself, fail, etc.
```

#### Demote a Master to Slave (make it replicate another master)

```bash
# Step 1: Get the node ID of the target master (the one you want this node to replicate)
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <target-master-ip> -p <target-master-port> cluster myid

# Step 2: Tell the node to become a slave of the target master
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <node-to-demote-ip> -p <node-to-demote-port> cluster replicate <target-master-node-id>
```

**Example:** Make node 7004 a slave of node 7001
```bash
# Get 7001's node ID
MASTER_ID=$(docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <node-b1-ip> -p 7001 cluster myid)

# Make 7004 replicate 7001
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <node-b1-ip> -p 7004 cluster replicate $MASTER_ID
```

#### Promote a Slave to Master (failover)

```bash
# Run CLUSTER FAILOVER on the slave you want to promote
# This will make it take over as master (the old master becomes slave)
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <slave-ip> -p <slave-port> cluster failover

# Force failover (use when master is down or unresponsive)
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <slave-ip> -p <slave-port> cluster failover force

# Takeover (use when master is completely unreachable and majority agreement not possible)
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <slave-ip> -p <slave-port> cluster failover takeover
```

**Example:** Promote node 7003 (currently a slave) back to master
```bash
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <node-b3-ip> -p 7003 cluster failover
```

#### Verify Role Change

```bash
# Check the node's current role
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <node-ip> -p <port> role

# Output: "master" or "slave"
```

#### Common Scenarios

| Scenario | Command to Use |
|----------|----------------|
| Slave is acting as master, original master is back up | Run `CLUSTER FAILOVER` on original master |
| Master is acting as slave | Run `CLUSTER FAILOVER` on the node to promote it |
| Force a specific node to become slave | Run `CLUSTER REPLICATE <master-id>` on the node |
| Emergency promotion when master is down | Run `CLUSTER FAILOVER FORCE` on slave |

#### Reset/Delete Cluster

**⚠️ WARNING: These commands will destroy all data in the cluster!**

```bash
# Step 1: Reset each node individually (run on ALL 6 nodes)
# This removes cluster configuration and flushes all data

# Reset node 7001
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <node-b1-ip> -p 7001 cluster reset hard

# Reset node 7002
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <node-b2-ip> -p 7002 cluster reset hard

# Reset node 7003
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <node-b3-ip> -p 7003 cluster reset hard

# Reset node 7004
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <node-b1-ip> -p 7004 cluster reset hard

# Reset node 7005
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <node-b2-ip> -p 7005 cluster reset hard

# Reset node 7006
docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
  -h <node-b3-ip> -p 7006 cluster reset hard
```

**One-liner to reset all nodes (using environment variables):**
```bash
# Make sure to source your .env file first: source .env
for port in 7001 7002 7003 7004 7005 7006; do
  case $port in
    7001|7004) host=$NODE_B1_IP ;;
    7002|7005) host=$NODE_B2_IP ;;
    7003|7006) host=$NODE_B3_IP ;;
  esac
  echo "Resetting $host:$port..."
  docker run --rm --network host -e REDISCLI_AUTH=$REDIS_PASSWORD redis:7.4.7-alpine redis-cli \
    -h $host -p $port cluster reset hard
done
```

**After resetting, you can recreate the cluster:**
```bash
./02-create-redis-cluster.sh
```

| Reset Type | Description |
|------------|-------------|
| `CLUSTER RESET SOFT` | Resets cluster config but keeps data |
| `CLUSTER RESET HARD` | Resets cluster config AND flushes all data |

## Troubleshooting

### Check Node Connectivity

```bash
docker run --rm --network redis-net redis:7.4.7-alpine redis-cli -h <node-ip> -p 7001 -a <password> ping
```

### View Cluster Information

```bash
redis-cli -h <node-b1-ip> -p 7001 -a <your-password> cluster info
```

### Reset Cluster (if needed)

```bash
redis-cli -h <node-b1-ip> -p 7001 -a <your-password> cluster reset
```

## Security Notes

- Change default Redis password in production
- Use strong passwords (25+ characters)
- Configure firewall rules for Redis ports
- Enable TLS if required for production

## Performance Tuning

- Monitor memory usage per node (2GB limit configured)
- Adjust CPU limits based on workload
- Configure Redis persistence based on requirements
- Monitor cluster slot distribution

## Files Structure

```
├── .env                        # Environment configuration
├── .env.example                # Environment template
├── 01-build-redis-conf.sh      # Configuration builder script
├── 02-create-redis-cluster.sh  # Cluster initialization script
├── 03-test-redis-cluster.sh    # Cluster testing and monitoring script
├── redis-stack.yml             # Docker Swarm stack definition
├── redis-cluster.tmpl          # Redis configuration template
├── conf/                       # Generated Redis configurations
│   ├── redis-7001.conf
│   ├── redis-7002.conf
│   └── ...
└── README.md                   # This documentation
```

## References

### Official Documentation

- [Redis Cluster Tutorial](https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/) - Official Redis cluster setup guide
- [Redis Configuration](https://redis.io/docs/latest/operate/oss_and_stack/management/config/) - Redis configuration parameters reference
- [Redis Commands](https://redis.io/docs/latest/commands/) - Complete Redis commands documentation
- [Docker Swarm Mode](https://docs.docker.com/engine/swarm/) - Docker Swarm orchestration guide

### Redis Cluster Commands Reference

| Command | Description | Example |
|---------|-------------|---------|
| `CLUSTER INFO` | Show cluster status | `redis-cli cluster info` |
| `CLUSTER NODES` | List all cluster nodes | `redis-cli cluster nodes` |
| `CLUSTER SLOTS` | Show slot assignment | `redis-cli cluster slots` |
| `CLUSTER RESET` | Reset cluster configuration | `redis-cli cluster reset` |
| `CLUSTER FAILOVER` | Manual failover | `redis-cli cluster failover` |
| `CLUSTER FORGET` | Remove node from cluster | `redis-cli cluster forget <node-id>` |

### Docker Commands Reference

| Command | Description | Example |
|---------|-------------|---------|
| `docker stack deploy` | Deploy stack | `docker stack deploy -c file.yml name` |
| `docker stack services` | List stack services | `docker stack services redis` |
| `docker service logs` | View service logs | `docker service logs -f service_name` |
| `docker service ps` | List service tasks | `docker service ps service_name` |
| `docker service scale` | Scale service | `docker service scale service=replicas` |

### Redis Configuration Parameters

| Parameter | Description | Default | Cluster Value |
|-----------|-------------|---------|---------------|
| `port` | Redis port | 6379 | 7001-7006 |
| `cluster-enabled` | Enable cluster mode | no | yes |
| `cluster-config-file` | Cluster config file | - | nodes.conf |
| `cluster-node-timeout` | Node timeout (ms) | 15000 | 5000 |
| `cluster-announce-ip` | Announce IP | - | ${IP} |
| `cluster-announce-port` | Announce port | - | ${PORT} |
| `cluster-announce-bus-port` | Cluster bus port | - | 1${PORT} |

### Spring Boot Redis Properties

| Property | Description | Example |
|----------|-------------|---------|
| `spring.data.redis.cluster.nodes` | Cluster node list | host:7001,host:7002 |
| `spring.data.redis.cluster.max-redirects` | Max redirections | 3 |
| `spring.data.redis.password` | Redis password | your_password |
| `spring.data.redis.timeout` | Connection timeout | 3000ms |
| `spring.data.redis.lettuce.pool.max-active` | Max connections | 20 |

### Environment Variables

| Variable | Description | Example | Required |
|----------|-------------|---------|----------|
| `NODE_B1_IP` | Physical node b1 IP | 192.168.0.12 | ✅ |
| `NODE_B2_IP` | Physical node b2 IP | 192.168.0.13 | ✅ |
| `NODE_B3_IP` | Physical node b3 IP | 192.168.0.14 | ✅ |
| `REDIS_PASSWORD` | Authentication password | secure_password | ✅ |

### Port Mapping

| Service | External Port | Internal Port | Cluster Bus | Physical Node |
|---------|---------------|---------------|-------------|---------------|
| redis1 | 7001 | 6379 | 17001→16379 | b1 (master) |
| redis2 | 7002 | 6379 | 17002→16379 | b2 (master) |
| redis3 | 7003 | 6379 | 17003→16379 | b3 (master) |
| redis4 | 7004 | 6379 | 17004→16379 | b1 (replica) |
| redis5 | 7005 | 6379 | 17005→16379 | b2 (replica) |
| redis6 | 7006 | 6379 | 17006→16379 | b3 (replica) |

### Useful Tools

- **Redis CLI**: `redis-cli -h host -p port -a password`
- **Redis Insight**: Web-based Redis GUI
- **Docker Stats**: `docker stats` - Monitor container resources
- **Docker Logs**: `docker service logs -f service_name`
- **Skopeo**: List Docker image tags without pulling

### Quick Commands

```bash
# Check cluster health
redis-cli -h <node-b1-ip> -p 7001 -a <password> cluster info | grep cluster_state

# Get cluster slot distribution
redis-cli -h <node-b1-ip> -p 7001 -a <password> cluster slots

# Monitor Redis performance
redis-cli -h <node-b1-ip> -p 7001 -a <password> --latency-history

# Generate secure password
openssl rand -base64 32 | tr -d "=+/" | cut -c1-25

# List Docker image tags
curl -s "https://registry.hub.docker.com/v2/repositories/library/redis/tags/?page_size=20" | jq -r '.results[].name'

# Test connectivity to all nodes
for ip in <node-b1-ip> <node-b2-ip> <node-b3-ip>; do
  redis-cli -h $ip -p 7001 -a <password> ping
  redis-cli -h $ip -p 7002 -a <password> ping
done
```

---

## 👨‍💻 Author

<div align="center">
  <img src="https://github.com/villcabo.png" width="100" height="100" style="border-radius: 50%;" alt="villcabo">
  <br/>
  <strong>Bismarck Villca</strong>
  <br/>
  <br/>
  <a href="https://github.com/villcabo">
    <img src="https://img.shields.io/badge/GitHub-villcabo-blue?style=for-the-badge&logo=github" alt="GitHub Profile">
  </a>
  <br/>
  <a href="https://linkedin.com/in/villcabo">
    <img src="https://img.shields.io/badge/LinkedIn-villcabo-0A66C2?style=for-the-badge&logo=linkedin" alt="LinkedIn Profile">
  </a>
  <br/>
  <a href="https://facebook.com/villcabo">
    <img src="https://img.shields.io/badge/Facebook-villcabo-1877F2?style=for-the-badge&logo=facebook" alt="Facebook Profile">
  </a>
  <br/>
  <a href="https://x.com/villcabo">
    <img src="https://img.shields.io/badge/X-@villcabo-000000?style=for-the-badge&logo=x" alt="X Profile">
  </a>
  <br/>
</div>

---

⭐ **If this project helped you, please consider giving it a star!** ⭐
