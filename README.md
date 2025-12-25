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
- **IP**: Your Redis cluster IP address
- **REDIS_PASSWORD**: Secure password (use provided generation commands)
- **PORT_START/PORT_END**: Redis port range (default: 7001-7006)

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
./build-redis-conf.sh
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
./create-redis-cluster.sh
```

This command:
- Tests connectivity to all nodes
- Creates cluster with 3 masters and 3 replicas
- Verifies cluster status

## Step 8: Verification

### Check Cluster Status

```bash
redis-cli -h <your-ip> -p 7001 -a <your-password> cluster nodes
```

### Test Cluster Operations

```bash
redis-cli -h <your-ip> -p 7001 -a <your-password> set key1 "value1"
redis-cli -h <your-ip> -p 7002 -a <your-password> get key1
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
          - ${REDIS_HOST}:7001
          - ${REDIS_HOST}:7002
          - ${REDIS_HOST}:7003
          - ${REDIS_HOST}:7004
          - ${REDIS_HOST}:7005
          - ${REDIS_HOST}:7006
        max-redirects: 3
      password: ${REDIS_PASSWORD}
      timeout: 3000ms
      lettuce:
        cluster:
          refresh:
            adaptive: true
            period: 30s
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

## Troubleshooting

### Check Node Connectivity

```bash
docker run --rm --network redis-net redis:7.4.7-alpine redis-cli -h <ip> -p <port> -a <password> ping
```

### View Cluster Information

```bash
redis-cli -h <your-ip> -p 7001 -a <your-password> cluster info
```

### Reset Cluster (if needed)

```bash
redis-cli -h <your-ip> -p 7001 -a <your-password> cluster reset
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
| `IP` | Redis cluster IP | 192.168.0.12 | ✅ |
| `REDIS_PASSWORD` | Authentication password | secure_password | ✅ |
| `PORT_START` | First port number | 7001 | ✅ |
| `PORT_END` | Last port number | 7006 | ✅ |

### Port Mapping

| Service | Data Port | Cluster Bus | Physical Node |
|---------|-----------|-------------|---------------|
| redis1 | 7001 | 17001 | b1 (master) |
| redis2 | 7002 | 17002 | b2 (master) |
| redis3 | 7003 | 17003 | b3 (master) |
| redis4 | 7004 | 17004 | b1 (replica) |
| redis5 | 7005 | 17005 | b2 (replica) |
| redis6 | 7006 | 17006 | b3 (replica) |

### Useful Tools

- **Redis CLI**: `redis-cli -h host -p port -a password`
- **Redis Insight**: Web-based Redis GUI
- **Docker Stats**: `docker stats` - Monitor container resources
- **Docker Logs**: `docker service logs -f service_name`
- **Skopeo**: List Docker image tags without pulling

### Quick Commands

```bash
# Check cluster health
redis-cli -h <ip> -p 7001 -a <password> cluster info | grep cluster_state

# Get cluster slot distribution
redis-cli -h <ip> -p 7001 -a <password> cluster slots

# Monitor Redis performance
redis-cli -h <ip> -p 7001 -a <password> --latency-history

# Generate secure password
openssl rand -base64 32 | tr -d "=+/" | cut -c1-25

# List Docker image tags
curl -s "https://registry.hub.docker.com/v2/repositories/library/redis/tags/?page_size=30" | jq -r '.results[].name'
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
