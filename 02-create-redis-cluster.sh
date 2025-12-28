#!/bin/bash

# Safe Redis cluster initialization/maintenance script
# Detects cluster state, adds missing nodes, and manages roles without destructive resets

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
log_info() { echo "[INFO] $1"; }
log_success() { echo "${GREEN}[SUCCESS] $1${RESET}"; }
log_error() { echo "${RED}[ERROR] $1${RESET}"; }
log_warning() { echo "${YELLOW}[WARNING] $1${RESET}"; }

# Load environment variables from .env file
if [ -f .env ]; then
    log_info "Loading variables from .env file..."
    REDIS_PASSWORD=$(grep "^REDIS_PASSWORD=" .env | cut -d'=' -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d "'\"")
    NODE_B1_IP=$(grep "^NODE_B1_IP=" .env | cut -d'=' -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d "'\"")
    NODE_B2_IP=$(grep "^NODE_B2_IP=" .env | cut -d'=' -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d "'\"")
    NODE_B3_IP=$(grep "^NODE_B3_IP=" .env | cut -d'=' -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d "'\"")
    if [ -z "$REDIS_PASSWORD" ]; then log_error "REDIS_PASSWORD not found in .env file"; exit 1; fi
    if [ -z "$NODE_B1_IP" ] || [ -z "$NODE_B2_IP" ] || [ -z "$NODE_B3_IP" ]; then log_error "Node IP variables not found in .env file"; exit 1; fi
    log_success "Variables loaded successfully"
else
    log_error ".env file not found. Please create it with required variables."
    exit 1
fi

# Node/port definitions
MASTERS=("$NODE_B1_IP:7001" "$NODE_B2_IP:7002" "$NODE_B3_IP:7003")
SLAVES=("$NODE_B1_IP:7004" "$NODE_B2_IP:7005" "$NODE_B3_IP:7006")
ALL_NODES=("${MASTERS[@]}" "${SLAVES[@]}")

# Helper: run redis-cli in docker
redis_cli() {
    docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli -h "$1" -p "$2" "$@" || return 1
}

# Helper: get cluster nodes info from a reachable node
get_cluster_nodes_info() {
    for node in "${ALL_NODES[@]}"; do
        host="${node%%:*}"; port="${node##*:}"
        out=$(redis_cli "$host" "$port" cluster nodes 2>/dev/null || true)
        if [[ "$out" == *myself* ]]; then
            echo "$out"
            return 0
        fi
    done
    return 1
}

# Helper: get cluster info
get_cluster_info() {
    for node in "${ALL_NODES[@]}"; do
        host="${node%%:*}"; port="${node##*:}"
        out=$(redis_cli "$host" "$port" cluster info 2>/dev/null || true)
        if [[ "$out" == *cluster_state* ]]; then
            echo "$out"
            return 0
        fi
    done
    return 1
}

# Analyze cluster state
CLUSTER_NODES_RAW="$(get_cluster_nodes_info)"
CLUSTER_INFO_RAW="$(get_cluster_info)"

# Parse cluster state
cluster_exists=false
cluster_state="unknown"
missing_nodes=()
wrong_roles=()
recovery_actions=()
no_nodes_accessible=false

if [[ -z "$CLUSTER_NODES_RAW" && -z "$CLUSTER_INFO_RAW" ]]; then
    no_nodes_accessible=true
fi

if [[ -n "$CLUSTER_INFO_RAW" ]]; then
    cluster_exists=true
    cluster_state=$(echo "$CLUSTER_INFO_RAW" | grep cluster_state | cut -d: -f2 | tr -d '\r')
fi

# Build preview
PREVIEW="${YELLOW}=== PREVIEW OF OPERATIONS ===${RESET}\n\n"
PREVIEW+="Cluster detected: "
if [ "$no_nodes_accessible" = true ]; then
    PREVIEW+="${RED}COULD NOT QUERY ANY CLUSTER NODE${RESET}\n"
    PREVIEW+="\nCould not get information from any node. Containers may not be running or ports may not be accessible.\n"
    PREVIEW+="\nIf you want to create the cluster from scratch, make sure the nodes are available.\n"
    PREVIEW+="\nCluster creation from scratch will be attempted if you confirm.\n"
else
    if [ "$cluster_exists" = true ]; then
        PREVIEW+="${GREEN}YES${RESET} (state: $cluster_state)\n"
    else
        PREVIEW+="${RED}NO${RESET}\n"
    fi
    PREVIEW+="\n"
    # Parse current nodes and roles
    declare -A current_roles
    declare -A node_ids
    while read -r line; do
        node_id=$(echo "$line" | awk '{print $1}')
        addr=$(echo "$line" | awk '{print $2}' | cut -d'@' -f1)
        flags=$(echo "$line" | awk '{print $3}')
        current_roles["$addr"]="$flags"
        node_ids["$addr"]="$node_id"
    done <<< "$(echo "$CLUSTER_NODES_RAW" | grep -v '^$')"

    # Detect missing nodes
    for node in "${ALL_NODES[@]}"; do
        if [[ -z "${current_roles[$node]}" ]]; then
            missing_nodes+=("$node")
        fi
    done

    # Detect wrong roles (slaves promoted to master, etc)
    for i in 0 1 2; do
        master="${MASTERS[$i]}"
        slave="${SLAVES[$i]}"
        master_flags="${current_roles[$master]}"
        slave_flags="${current_roles[$slave]}"
        if [[ "$slave_flags" == *master* && "$master_flags" == *fail* ]]; then
            PREVIEW+="${YELLOW}Warning:${RESET} $slave is master because $master is down. Cannot revert while original master is unavailable.\n"
        elif [[ "$slave_flags" == *master* && "$master_flags" != *master* && -n "$master_flags" ]]; then
            wrong_roles+=("$slave (promoted to master, revert if $master available)")
            recovery_actions+=("Revert $slave to replica of $master")
        fi
    done

    if [ ${#missing_nodes[@]} -gt 0 ]; then
        PREVIEW+="\nMissing nodes to be added to the cluster:\n"
        for n in "${missing_nodes[@]}"; do
            PREVIEW+="  - $n\n"
        done
    else
        PREVIEW+="\nNo missing nodes in the cluster.\n"
    fi
    if [ ${#wrong_roles[@]} -gt 0 ]; then
        PREVIEW+="\nWrong roles detected:\n"
        for r in "${wrong_roles[@]}"; do
            PREVIEW+="  - $r\n"
        done
    fi
    if [ ${#recovery_actions[@]} -gt 0 ]; then
        PREVIEW+="\nSuggested recovery actions:\n"
        for a in "${recovery_actions[@]}"; do
            PREVIEW+="  - $a\n"
        done
    fi
fi
PREVIEW+="\n${RED}⚠️  No destructive reset will be performed. Only missing nodes will be added or the cluster will be created if it does not exist.${RESET}\n"
PREVIEW+="\nRedis password: [PROTECTED]"

# Show preview and ask for confirmation
echo -e "$PREVIEW"
echo -n "Do you want to proceed with the shown actions? [yes/No]: "
read -r confirmation
if [[ "$confirmation" != "yes" ]]; then
    log_warning "Operation cancelled by user."
    exit 0
fi

echo ""

# === ACTIONS ===
if [ "$no_nodes_accessible" = true ]; then
    log_warning "Could not query any node. Attempting to create the cluster from scratch..."
    NODES_ARGS=""
    for n in "${ALL_NODES[@]}"; do NODES_ARGS+="$n "; done
    docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
        --cluster create $NODES_ARGS --cluster-replicas 1 --cluster-yes
    log_success "Cluster created."
elif [ "$cluster_exists" = true ]; then
    # Add missing nodes
    for n in "${missing_nodes[@]}"; do
        host="${n%%:*}"; port="${n##*:}"
        log_info "Adding missing node $n to the cluster..."
        for ref in "${MASTERS[@]}"; do
            ref_host="${ref%%:*}"; ref_port="${ref##*:}"
            if redis_cli "$ref_host" "$ref_port" ping >/dev/null 2>&1; then
                redis_cli "$ref_host" "$ref_port" cluster add-node "$n" "$ref"
                break
            fi
        done
    done
    # Revert roles if needed
    for i in 0 1 2; do
        master="${MASTERS[$i]}"
        slave="${SLAVES[$i]}"
        master_flags="${current_roles[$master]}"
        slave_flags="${current_roles[$slave]}"
        if [[ "$slave_flags" == *master* && "$master_flags" == *master* ]]; then
            log_info "Reverting $slave to replica of $master..."
            slave_id="${node_ids[$slave]}"
            master_id="${node_ids[$master]}"
            host="${slave%%:*}"; port="${slave##*:}"
            redis_cli "$host" "$port" cluster replicate "$master_id"
        fi
    done
    log_success "Cluster updated."
else
    # Create cluster from scratch
    log_info "Creating cluster from scratch..."
    NODES_ARGS=""
    for n in "${ALL_NODES[@]}"; do NODES_ARGS+="$n "; done
    docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
        --cluster create $NODES_ARGS --cluster-replicas 1 --cluster-yes
    log_success "Cluster created."
fi

echo ""
log_info "Process finished. You can check the cluster state with redis-cli --cluster info."
