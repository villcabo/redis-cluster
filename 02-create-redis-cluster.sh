#!/bin/bash

# Redis cluster initialization script
# Creates a Redis cluster from deployed containers

set -e  # Exit on any error

# Load environment variables from .env file
if [ -f .env ]; then
    echo "[INFO] Loading environment variables from .env file..."
    source .env
    echo "[INFO] Environment variables loaded successfully"
else
    echo "[ERROR] .env file not found. Please create it with required variables."
    exit 1
fi

# Validate required environment variables
if [ -z "$IP" ]; then
    echo "[ERROR] IP variable not set in .env file"
    exit 1
fi

if [ -z "$PORT_START" ]; then
    echo "[ERROR] PORT_START variable not set in .env file"
    exit 1
fi

if [ -z "$PORT_END" ]; then
    echo "[ERROR] PORT_END variable not set in .env file"
    exit 1
fi

echo "[INFO] Redis Cluster Initialization"
echo "  - IP: $IP"
echo "  - Port range: $PORT_START - $PORT_END"
echo "  - Authentication: $([ -n "$REDIS_PASSWORD" ] && echo "Enabled" || echo "Disabled")"
echo ""

# Build the cluster nodes list
CLUSTER_NODES=""
for port in $(seq $PORT_START $PORT_END); do
    CLUSTER_NODES="$CLUSTER_NODES ${IP}:${port}"
done

echo "[INFO] Cluster nodes to create:$CLUSTER_NODES"
echo ""

# Prepare authentication parameter
AUTH_PARAM=""
if [ -n "$REDIS_PASSWORD" ]; then
    AUTH_PARAM="-a $REDIS_PASSWORD"
fi

echo "[INFO] Waiting for all Redis nodes to be ready..."
sleep 5

# Test connectivity to all nodes
echo "[INFO] Testing connectivity to Redis nodes..."
for port in $(seq $PORT_START $PORT_END); do
    echo -n "  - Testing ${IP}:${port}... "
    if docker run --rm --network redis-net redis:7.4.7-alpine redis-cli -h $IP -p $port $AUTH_PARAM ping >/dev/null 2>&1; then
        echo "✓ OK"
    else
        echo "✗ FAILED"
        echo "[ERROR] Cannot connect to Redis node ${IP}:${port}"
        exit 1
    fi
done

echo ""
echo "[INFO] All nodes are accessible. Creating Redis cluster..."
echo "[INFO] This will create 3 masters and 3 replicas automatically."
echo ""

# Create the Redis cluster using docker run
echo "[INFO] Executing cluster create command..."
docker run --rm --network redis-net redis:7.4.7-alpine redis-cli \
    --cluster create$CLUSTER_NODES \
    --cluster-replicas 1 \
    --cluster-yes \
    $AUTH_PARAM

if [ $? -eq 0 ]; then
    echo ""
    echo "[SUCCESS] ✅ Redis cluster created successfully!"
    echo ""
    echo "[INFO] Cluster status check:"
    
    # Show cluster status
    docker run --rm --network redis-net redis:7.4.7-alpine redis-cli \
        -h $IP -p $PORT_START $AUTH_PARAM \
        --cluster check ${IP}:${PORT_START}
    
    echo ""
    echo "[INFO] 🎉 Your Redis cluster is ready to use!"
    echo "      Connect to any node: ${IP}:${PORT_START} - ${IP}:${PORT_END}"
    echo "      Spring Boot config: Use all nodes in cluster configuration"
else
    echo ""
    echo "[ERROR] ❌ Failed to create Redis cluster"
    exit 1
fi