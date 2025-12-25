#!/bin/bash

# Redis cluster initialization script
# Creates a Redis cluster from deployed containers

set -e  # Exit on any error

# Color definitions using tput (more portable)
if [ -t 1 ]; then
    GREEN=$(tput setaf 2)
    RED=$(tput setaf 1)
    YELLOW=$(tput setaf 3)
    RESET=$(tput sgr0)
else
    GREEN=""
    RED=""
    YELLOW=""
    RESET=""
fi

# Logging functions
log_info() {
    echo "[INFO] $1"
}

log_success() {
    echo "${GREEN}[SUCCESS] $1${RESET}"
}

log_error() {
    echo "${RED}[ERROR] $1${RESET}"
}

log_warning() {
    echo "${YELLOW}[WARNING] $1${RESET}"
}

# Load environment variables from .env file
if [ -f .env ]; then
    log_info "Loading variables from .env file..."
    REDIS_PASSWORD=$(grep "^REDIS_PASSWORD=" .env | cut -d'=' -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"'"'"'')
    NODE_B1_IP=$(grep "^NODE_B1_IP=" .env | cut -d'=' -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"'"'"'')
    NODE_B2_IP=$(grep "^NODE_B2_IP=" .env | cut -d'=' -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"'"'"'')
    NODE_B3_IP=$(grep "^NODE_B3_IP=" .env | cut -d'=' -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"'"'"'')

    if [ -z "$REDIS_PASSWORD" ]; then
        log_error "REDIS_PASSWORD not found in .env file"
        exit 1
    fi
    if [ -z "$NODE_B1_IP" ] || [ -z "$NODE_B2_IP" ] || [ -z "$NODE_B3_IP" ]; then
        log_error "Node IP variables not found in .env file"
        exit 1
    fi
    log_success "Variables loaded successfully"
else
    log_error ".env file not found. Please create it with required variables."
    exit 1
fi

log_info "Redis Cluster Initialization"
echo "  - Node B1 IP: $NODE_B1_IP (ports 7001, 7004)"
echo "  - Node B2 IP: $NODE_B2_IP (ports 7002, 7005)"
echo "  - Node B3 IP: $NODE_B3_IP (ports 7003, 7006)"
echo "  - Authentication: $([ -n "$REDIS_PASSWORD" ] && echo "Enabled" || echo "Disabled")"
echo ""

# Build the cluster nodes list using external IPs with specific ports
CLUSTER_NODES=""
SERVICE_PORTS=(7001 7002 7003 7004 7005 7006)
NODE_IPS=("$NODE_B1_IP" "$NODE_B2_IP" "$NODE_B3_IP" "$NODE_B1_IP" "$NODE_B2_IP" "$NODE_B3_IP")

# Construct cluster nodes list with external IPs and their specific ports
for i in "${!NODE_IPS[@]}"; do
    NODE_IP="${NODE_IPS[$i]}"
    PORT="${SERVICE_PORTS[$i]}"
    CLUSTER_NODES="$CLUSTER_NODES ${NODE_IP}:${PORT}"
done

log_info "Cluster nodes to create:$CLUSTER_NODES"
log_info "Using external IP addresses for cluster creation"
echo ""

# Function to reset cluster nodes
reset_cluster_nodes() {
    log_info "Checking and resetting cluster nodes if needed..."

    for i in "${!NODE_IPS[@]}"; do
        NODE_IP="${NODE_IPS[$i]}"
        PORT="${SERVICE_PORTS[$i]}"
        echo -n "  - Resetting node ${NODE_IP}:${PORT}... "

        # Try to reset the cluster configuration
        if docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
            -h $NODE_IP -p $PORT --cluster-only-masters --cluster-yes cluster reset >/dev/null 2>&1; then
            echo "OK (was in cluster)"
        else
            # If reset fails, try to flush the database
            if docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
                -h $NODE_IP -p $PORT flushall >/dev/null 2>&1; then
                echo "OK (flushed data)"
            else
                echo "OK (clean node)"
            fi
        fi
    done
    echo ""
}

# Reset nodes before creating cluster
reset_cluster_nodes

# Prepare authentication using environment variable (safer than -a parameter)
if [ -n "$REDIS_PASSWORD" ]; then
    export REDISCLI_AUTH="$REDIS_PASSWORD"
    log_info "Authentication configured via REDISCLI_AUTH"
fi

log_info "Waiting for all Redis nodes to be ready..."
sleep 10

log_info "Creating Redis cluster..."
log_info "This will create 3 masters and 3 replicas automatically."
echo ""

# Create the Redis cluster using docker run
log_info "Executing cluster create command..."
docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
    --cluster create$CLUSTER_NODES \
    --cluster-replicas 1 \
    --cluster-yes

if [ $? -eq 0 ]; then
    echo ""
    log_success "Redis cluster created successfully!"
    echo ""
    log_info "Cluster services:"
    echo "  - External access: ${NODE_B1_IP}:7001, ${NODE_B2_IP}:7002, ${NODE_B3_IP}:7003, ${NODE_B1_IP}:7004, ${NODE_B2_IP}:7005, ${NODE_B3_IP}:7006"
    echo ""
    log_info "Use script 03-test-redis-cluster.sh to test cluster functionality"
else
    echo ""
    log_error "Failed to create Redis cluster"
    exit 1
fi
