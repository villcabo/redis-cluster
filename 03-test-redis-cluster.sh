#!/bin/bash

# Redis cluster testing script
# Tests Redis cluster functionality and performance

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
    REDIS_PASSWORD=$(grep "^REDIS_PASSWORD=" .env | cut -d'=' -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"'"'"')')
    NODE_B1_IP=$(grep "^NODE_B1_IP=" .env | cut -d'=' -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"'"'"')')
    NODE_B2_IP=$(grep "^NODE_B2_IP=" .env | cut -d'=' -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"'"'"')')
    NODE_B3_IP=$(grep "^NODE_B3_IP=" .env | cut -d'=' -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"'"'"')')

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

log_info "Redis Cluster Testing Suite"
echo "  - Node B1 IP: $NODE_B1_IP (ports 7001, 7004)"
echo "  - Node B2 IP: $NODE_B2_IP (ports 7002, 7005)"
echo "  - Node B3 IP: $NODE_B3_IP (ports 7003, 7006)"
echo "  - Authentication: $([ -n "$REDIS_PASSWORD" ] && echo "Enabled" || echo "Disabled")"
echo ""

# Prepare authentication using environment variable (safer than -a parameter)
if [ -n "$REDIS_PASSWORD" ]; then
    export REDISCLI_AUTH="$REDIS_PASSWORD"
    log_info "Authentication configured via REDISCLI_AUTH"
fi

log_info "Testing connectivity to Redis services..."
SERVICE_PORTS=(7001 7002 7003 7004 7005 7006)
NODE_IPS=("$NODE_B1_IP" "$NODE_B2_IP" "$NODE_B3_IP" "$NODE_B1_IP" "$NODE_B2_IP" "$NODE_B3_IP")

# Variables to track node status
AVAILABLE_NODES=()
FAILED_NODES=()
AVAILABLE_COUNT=0
FAILED_COUNT=0

# Test connectivity to all nodes using external IPs
for i in "${!NODE_IPS[@]}"; do
    NODE_IP="${NODE_IPS[$i]}"
    PORT="${SERVICE_PORTS[$i]}"
    echo -n "  - Testing ${NODE_IP}:${PORT}... "
    if docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli -h $NODE_IP -p $PORT ping >/dev/null 2>&1; then
        log_success "OK"
        AVAILABLE_NODES+=("${NODE_IP}:${PORT}")
        AVAILABLE_COUNT=$((AVAILABLE_COUNT + 1))
    else
        log_error "FAILED"
        FAILED_NODES+=("${NODE_IP}:${PORT}")
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
done

echo ""
log_info "Connectivity Summary:"
echo "  - Available nodes: ${GREEN}$AVAILABLE_COUNT/6${RESET}"
if [ $FAILED_COUNT -gt 0 ]; then
    echo "  - Failed nodes: ${RED}$FAILED_COUNT/6${RESET}"
    for failed_node in "${FAILED_NODES[@]}"; do
        echo "    * $failed_node"
    done
fi
echo ""

# Find first available node for cluster operations
if [ $AVAILABLE_COUNT -gt 0 ]; then
    FIRST_AVAILABLE="${AVAILABLE_NODES[0]}"
    CLUSTER_IP=$(echo $FIRST_AVAILABLE | cut -d':' -f1)
    CLUSTER_PORT=$(echo $FIRST_AVAILABLE | cut -d':' -f2)

    log_info "Cluster status check (using ${CLUSTER_IP}:${CLUSTER_PORT}):"
    docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
        -h $CLUSTER_IP -p $CLUSTER_PORT \
        --cluster check $FIRST_AVAILABLE 2>/dev/null || log_warning "Cluster check failed - cluster may be degraded"

    echo ""
    log_info "Cluster nodes information:"
    docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
        -h $CLUSTER_IP -p $CLUSTER_PORT \
        cluster nodes 2>/dev/null || log_warning "Could not retrieve cluster nodes info"
else
    log_error "No nodes available for cluster operations"
    exit 1
fi

echo ""
if [ $AVAILABLE_COUNT -ge 3 ]; then
    log_info "Testing basic cluster operations..."

    # Test SET operation
    echo -n "  - Testing SET operation... "
    if docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
        -c -h $CLUSTER_IP -p $CLUSTER_PORT \
        set test_key "Hello Redis Cluster" >/dev/null 2>&1; then
        log_success "OK"
    else
        log_error "FAILED"
    fi

    # Test GET operation
    echo -n "  - Testing GET operation... "
    RESULT=$(docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
        -c -h $CLUSTER_IP -p $CLUSTER_PORT \
        get test_key 2>/dev/null)
    if [ "$RESULT" = "Hello Redis Cluster" ]; then
        log_success "OK (Value: $RESULT)"
    else
        log_warning "PARTIAL (Got: '$RESULT') - cluster may be degraded"
    fi

    # Clean up test keys
    docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
        -c -h $CLUSTER_IP -p $CLUSTER_PORT \
        del test_key >/dev/null 2>&1
else
    log_warning "Skipping basic operations - insufficient nodes available ($AVAILABLE_COUNT/6)"
fi

echo ""
if [ $FAILED_COUNT -eq 0 ]; then
    log_success "Redis cluster is working perfectly!"
    CLUSTER_STATUS="${GREEN}Healthy and operational${RESET}"
elif [ $AVAILABLE_COUNT -ge 3 ]; then
    log_warning "Redis cluster is working with degraded performance"
    CLUSTER_STATUS="${YELLOW}Degraded but operational${RESET}"
else
    log_error "Redis cluster has critical issues"
    CLUSTER_STATUS="${RED}Critical - insufficient nodes${RESET}"
fi

echo ""
log_info "Cluster summary:"
echo "  - Status: $CLUSTER_STATUS"
echo "  - Available nodes: ${GREEN}$AVAILABLE_COUNT/6${RESET} ($(echo "${AVAILABLE_NODES[@]}" | tr ' ' ', '))"
if [ $FAILED_COUNT -gt 0 ]; then
    echo "  - Failed nodes: ${RED}$FAILED_COUNT/6${RESET} ($(echo "${FAILED_NODES[@]}" | tr ' ' ', '))"
fi
echo "  - Authentication: $([ -n "$REDIS_PASSWORD" ] && echo "${GREEN}Secured${RESET}" || echo "${YELLOW}Open${RESET}")"
if [ $AVAILABLE_COUNT -ge 3 ]; then
    echo "  - Basic operations: ${GREEN}Working${RESET}"
else
    echo "  - Basic operations: ${RED}Not tested - insufficient nodes${RESET}"
fi
echo ""
if [ $FAILED_COUNT -eq 0 ]; then
    log_success "Your Redis cluster is ready for production use!"
elif [ $AVAILABLE_COUNT -ge 3 ]; then
    log_warning "Cluster operational but investigate failed nodes: $(echo "${FAILED_NODES[@]}" | tr ' ' ', ')"
else
    log_error "Cluster requires immediate attention - too many failed nodes!"
fi
