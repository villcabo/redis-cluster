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
no_nodes_accessible=false

# Arrays for actions
missing_masters=()
missing_slaves=()
failover_recovery=()  # Masters to restore from failover
down_slaves=()        # Slaves that are down (no action needed)
down_masters=()       # Masters that are down

# Associative arrays for node status
declare -A current_roles
declare -A node_ids
declare -A node_reachable

if [[ -z "$CLUSTER_NODES_RAW" && -z "$CLUSTER_INFO_RAW" ]]; then
    no_nodes_accessible=true
fi

if [[ -n "$CLUSTER_INFO_RAW" ]]; then
    cluster_exists=true
    cluster_state=$(echo "$CLUSTER_INFO_RAW" | grep cluster_state | cut -d: -f2 | tr -d '\r')
fi

# Check reachability of each node
check_node_reachable() {
    local host="${1%%:*}"
    local port="${1##*:}"
    docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
        -h "$host" -p "$port" ping 2>/dev/null | grep -q "PONG"
}

# Parse cluster nodes info if available
if [[ -n "$CLUSTER_NODES_RAW" ]]; then
    while read -r line; do
        [[ -z "$line" ]] && continue
        node_id=$(echo "$line" | awk '{print $1}')
        addr=$(echo "$line" | awk '{print $2}' | cut -d'@' -f1)
        flags=$(echo "$line" | awk '{print $3}')
        current_roles["$addr"]="$flags"
        node_ids["$addr"]="$node_id"
    done <<< "$CLUSTER_NODES_RAW"
fi

# Check reachability of all expected nodes
for node in "${ALL_NODES[@]}"; do
    if check_node_reachable "$node"; then
        node_reachable["$node"]="yes"
    else
        node_reachable["$node"]="no"
    fi
done

# Analyze each master-slave pair
for i in 0 1 2; do
    master="${MASTERS[$i]}"
    slave="${SLAVES[$i]}"
    master_flags="${current_roles[$master]}"
    slave_flags="${current_roles[$slave]}"
    master_up="${node_reachable[$master]}"
    slave_up="${node_reachable[$slave]}"
    
    # Check if nodes are in cluster
    master_in_cluster=false
    slave_in_cluster=false
    [[ -n "$master_flags" ]] && master_in_cluster=true
    [[ -n "$slave_flags" ]] && slave_in_cluster=true
    
    # Case 1: Master down, slave is now master
    if [[ "$slave_flags" == *master* && ("$master_flags" == *fail* || "$master_up" == "no") ]]; then
        if [[ "$master_up" == "yes" ]]; then
            # Master is back up! Need to do failover recovery
            failover_recovery+=("$i")
        else
            down_masters+=("$master (slave $slave acting as master)")
        fi
    fi
    
    # Case 2: Slave down - just note it, no action
    if [[ "$slave_up" == "no" || "$slave_flags" == *fail* ]]; then
        if [[ "$slave_flags" != *master* ]]; then
            down_slaves+=("$slave")
        fi
    fi
    
    # Case 3: Master not in cluster but reachable
    if [[ "$master_in_cluster" == "false" && "$master_up" == "yes" ]]; then
        missing_masters+=("$master")
    fi
    
    # Case 4: Slave not in cluster but reachable
    if [[ "$slave_in_cluster" == "false" && "$slave_up" == "yes" ]]; then
        missing_slaves+=("$i")  # Store index to know which master it belongs to
    fi
done

# Build preview
PREVIEW="${YELLOW}=== PREVIEW OF OPERATIONS ===${RESET}\n\n"

# Show expected structure
PREVIEW+="${YELLOW}Expected Cluster Structure:${RESET}\n"
PREVIEW+="┌─────────────────────────────────────────────────────────────┐\n"
for i in 0 1 2; do
    PREVIEW+="│ Pair $((i+1)): ${MASTERS[$i]} (MASTER) ← ${SLAVES[$i]} (SLAVE) │\n"
done
PREVIEW+="└─────────────────────────────────────────────────────────────┘\n\n"

PREVIEW+="Cluster detected: "
if [ "$no_nodes_accessible" = true ]; then
    PREVIEW+="${RED}COULD NOT QUERY ANY CLUSTER NODE${RESET}\n"
    PREVIEW+="\nCould not get information from any node. Containers may not be running or ports may not be accessible.\n"
    PREVIEW+="\n${YELLOW}Action:${RESET} Cluster creation from scratch will be attempted if you confirm.\n"
else
    if [ "$cluster_exists" = true ]; then
        PREVIEW+="${GREEN}YES${RESET} (state: $cluster_state)\n"
    else
        PREVIEW+="${RED}NO${RESET}\n"
    fi
    
    # Show current status of each node
    PREVIEW+="\n${YELLOW}Current Node Status:${RESET}\n"
    for i in 0 1 2; do
        master="${MASTERS[$i]}"
        slave="${SLAVES[$i]}"
        master_flags="${current_roles[$master]}"
        slave_flags="${current_roles[$slave]}"
        master_up="${node_reachable[$master]}"
        slave_up="${node_reachable[$slave]}"
        
        # Master status
        if [[ "$master_up" == "yes" ]]; then
            if [[ "$master_flags" == *master* ]]; then
                PREVIEW+="  ${GREEN}✓${RESET} $master - UP (master) ✓\n"
            elif [[ "$master_flags" == *slave* ]]; then
                PREVIEW+="  ${YELLOW}⚠${RESET} $master - UP (slave - WRONG ROLE)\n"
            elif [[ -z "$master_flags" ]]; then
                PREVIEW+="  ${YELLOW}⚠${RESET} $master - UP (not in cluster)\n"
            else
                PREVIEW+="  ${YELLOW}⚠${RESET} $master - UP ($master_flags)\n"
            fi
        else
            PREVIEW+="  ${RED}✗${RESET} $master - DOWN\n"
        fi
        
        # Slave status
        if [[ "$slave_up" == "yes" ]]; then
            if [[ "$slave_flags" == *slave* ]]; then
                PREVIEW+="  ${GREEN}✓${RESET} $slave - UP (slave) ✓\n"
            elif [[ "$slave_flags" == *master* ]]; then
                PREVIEW+="  ${YELLOW}⚠${RESET} $slave - UP (master - promoted by failover)\n"
            elif [[ -z "$slave_flags" ]]; then
                PREVIEW+="  ${YELLOW}⚠${RESET} $slave - UP (not in cluster)\n"
            else
                PREVIEW+="  ${YELLOW}⚠${RESET} $slave - UP ($slave_flags)\n"
            fi
        else
            PREVIEW+="  ${RED}✗${RESET} $slave - DOWN\n"
        fi
        PREVIEW+="\n"
    done
    
    # Show actions that WILL be performed
    PREVIEW+="${YELLOW}Actions to be performed:${RESET}\n"
    has_actions=false
    
    # Failover recovery actions
    if [ ${#failover_recovery[@]} -gt 0 ]; then
        has_actions=true
        PREVIEW+="\n${GREEN}[FAILOVER RECOVERY]${RESET} Restore original master-slave structure:\n"
        for idx in "${failover_recovery[@]}"; do
            master="${MASTERS[$idx]}"
            slave="${SLAVES[$idx]}"
            PREVIEW+="  → Promote $master back to MASTER\n"
            PREVIEW+="  → Demote $slave back to SLAVE of $master\n"
        done
    fi
    
    # Missing masters to add
    if [ ${#missing_masters[@]} -gt 0 ]; then
        has_actions=true
        PREVIEW+="\n${GREEN}[ADD MASTERS]${RESET} Add missing master nodes:\n"
        for m in "${missing_masters[@]}"; do
            PREVIEW+="  → Add $m to cluster as master\n"
        done
    fi
    
    # Missing slaves to add
    if [ ${#missing_slaves[@]} -gt 0 ]; then
        has_actions=true
        PREVIEW+="\n${GREEN}[ADD SLAVES]${RESET} Add missing slave nodes:\n"
        for idx in "${missing_slaves[@]}"; do
            slave="${SLAVES[$idx]}"
            master="${MASTERS[$idx]}"
            PREVIEW+="  → Add $slave to cluster as slave of $master\n"
        done
    fi
    
    # Show what will NOT be done
    if [ ${#down_slaves[@]} -gt 0 ]; then
        PREVIEW+="\n${YELLOW}[NO ACTION]${RESET} Down slaves (will be ignored):\n"
        for s in "${down_slaves[@]}"; do
            PREVIEW+="  - $s is down, no action needed\n"
        done
    fi
    
    if [ ${#down_masters[@]} -gt 0 ]; then
        PREVIEW+="\n${RED}[WAITING]${RESET} Down masters (cannot restore until they are back):\n"
        for m in "${down_masters[@]}"; do
            PREVIEW+="  - $m\n"
        done
    fi
    
    if [ "$has_actions" = false ] && [ ${#down_slaves[@]} -eq 0 ] && [ ${#down_masters[@]} -eq 0 ]; then
        PREVIEW+="  ${GREEN}✓ Cluster is healthy, no actions needed.${RESET}\n"
    fi
fi

PREVIEW+="\n${RED}⚠️  No destructive reset will be performed. Only structure restoration and missing nodes will be handled.${RESET}\n"
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
    
    # Step 1: Create cluster with only masters (no replicas)
    log_info "Creating cluster with masters only..."
    MASTERS_ARGS=""
    for n in "${MASTERS[@]}"; do MASTERS_ARGS+="$n "; done
    docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
        --cluster create $MASTERS_ARGS --cluster-yes
    
    # Wait for cluster to stabilize
    sleep 3
    
    # Step 2: Get master node IDs
    log_info "Getting master node IDs..."
    declare -A master_node_ids
    for master in "${MASTERS[@]}"; do
        host="${master%%:*}"; port="${master##*:}"
        node_id=$(docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
            -h "$host" -p "$port" cluster myid 2>/dev/null | tr -d '\r')
        master_node_ids["$master"]="$node_id"
        log_info "Master $master has ID: $node_id"
    done
    
    # Step 3: Add each slave and assign to its corresponding master
    # Mapping: SLAVES[0] -> MASTERS[0], SLAVES[1] -> MASTERS[1], etc.
    for i in 0 1 2; do
        slave="${SLAVES[$i]}"
        master="${MASTERS[$i]}"
        master_id="${master_node_ids[$master]}"
        slave_host="${slave%%:*}"; slave_port="${slave##*:}"
        ref_host="${MASTERS[0]%%:*}"; ref_port="${MASTERS[0]##*:}"
        
        log_info "Adding slave $slave to cluster..."
        docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
            --cluster add-node "$slave" "${MASTERS[0]}" --cluster-slave --cluster-master-id "$master_id"
        
        sleep 1
    done
    
    log_success "Cluster created with specific master-slave assignments."
    log_info "Master-Slave mapping:"
    for i in 0 1 2; do
        log_info "  ${MASTERS[$i]} (master) <- ${SLAVES[$i]} (slave)"
    done
elif [ "$cluster_exists" = true ]; then
    actions_performed=false
    
    # 1. Failover Recovery - Restore original master-slave structure
    if [ ${#failover_recovery[@]} -gt 0 ]; then
        actions_performed=true
        log_info "Performing failover recovery..."
        
        for idx in "${failover_recovery[@]}"; do
            master="${MASTERS[$idx]}"
            slave="${SLAVES[$idx]}"
            master_host="${master%%:*}"; master_port="${master##*:}"
            slave_host="${slave%%:*}"; slave_port="${slave##*:}"
            
            # Get the current master ID (the slave that took over)
            slave_node_id="${node_ids[$slave]}"
            
            # Step 1: Perform CLUSTER FAILOVER on the original master to take back control
            log_info "Triggering failover on $master to restore it as master..."
            
            # First, we need to make sure the original master is synced with the current master (slave)
            # The original master should be connected to the cluster and syncing
            
            # Get the master ID for the original master
            master_node_id=$(docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
                -h "$master_host" -p "$master_port" cluster myid 2>/dev/null | tr -d '\r')
            
            if [[ -n "$master_node_id" ]]; then
                # If the original master is currently a slave of the promoted slave, 
                # we can trigger CLUSTER FAILOVER on it
                log_info "Executing CLUSTER FAILOVER on $master..."
                docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
                    -h "$master_host" -p "$master_port" cluster failover 2>/dev/null || true
                
                sleep 2
                
                # Verify the failover worked
                new_role=$(docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
                    -h "$master_host" -p "$master_port" role 2>/dev/null | head -1 | tr -d '\r')
                
                if [[ "$new_role" == "master" ]]; then
                    log_success "$master is now master again"
                    
                    # Now ensure the slave is replicating the master
                    log_info "Ensuring $slave is replicating $master..."
                    docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
                        -h "$slave_host" -p "$slave_port" cluster replicate "$master_node_id" 2>/dev/null || true
                    
                    log_success "Failover recovery completed for pair: $master <- $slave"
                else
                    log_warning "Failover may not have completed. Current role of $master: $new_role"
                fi
            else
                log_error "Could not get node ID for $master"
            fi
        done
    fi
    
    # 2. Add missing masters
    if [ ${#missing_masters[@]} -gt 0 ]; then
        actions_performed=true
        log_info "Adding missing master nodes..."
        
        # Find a reference node that is reachable
        ref_node=""
        for node in "${ALL_NODES[@]}"; do
            if [[ "${node_reachable[$node]}" == "yes" && -n "${current_roles[$node]}" ]]; then
                ref_node="$node"
                break
            fi
        done
        
        if [[ -n "$ref_node" ]]; then
            for m in "${missing_masters[@]}"; do
                log_info "Adding $m to cluster..."
                docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
                    --cluster add-node "$m" "$ref_node" 2>/dev/null || true
                sleep 1
            done
        else
            log_error "No reference node available to add masters"
        fi
    fi
    
    # 3. Add missing slaves with correct master assignment
    if [ ${#missing_slaves[@]} -gt 0 ]; then
        actions_performed=true
        log_info "Adding missing slave nodes..."
        
        # Find a reference node that is reachable
        ref_node=""
        for node in "${ALL_NODES[@]}"; do
            if [[ "${node_reachable[$node]}" == "yes" && -n "${current_roles[$node]}" ]]; then
                ref_node="$node"
                break
            fi
        done
        
        if [[ -n "$ref_node" ]]; then
            for idx in "${missing_slaves[@]}"; do
                slave="${SLAVES[$idx]}"
                master="${MASTERS[$idx]}"
                master_host="${master%%:*}"; master_port="${master##*:}"
                
                # Get the master ID
                master_node_id=$(docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
                    -h "$master_host" -p "$master_port" cluster myid 2>/dev/null | tr -d '\r')
                
                if [[ -n "$master_node_id" ]]; then
                    log_info "Adding $slave as slave of $master (ID: $master_node_id)..."
                    docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
                        --cluster add-node "$slave" "$ref_node" --cluster-slave --cluster-master-id "$master_node_id" 2>/dev/null || true
                    sleep 1
                else
                    log_warning "Could not get master ID for $master, adding $slave as regular node"
                    docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
                        --cluster add-node "$slave" "$ref_node" 2>/dev/null || true
                fi
            done
        else
            log_error "No reference node available to add slaves"
        fi
    fi
    
    # 4. Down slaves - explicitly skip
    if [ ${#down_slaves[@]} -gt 0 ]; then
        log_info "Skipping ${#down_slaves[@]} down slave(s) - no action needed"
    fi
    
    if [ "$actions_performed" = true ]; then
        log_success "Cluster maintenance completed."
    else
        log_success "Cluster is healthy, no actions were needed."
    fi
else
    # Create cluster from scratch with specific master-slave assignments
    log_info "Creating cluster from scratch..."
    
    # Step 1: Create cluster with only masters (no replicas)
    log_info "Creating cluster with masters only..."
    MASTERS_ARGS=""
    for n in "${MASTERS[@]}"; do MASTERS_ARGS+="$n "; done
    docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
        --cluster create $MASTERS_ARGS --cluster-yes
    
    # Wait for cluster to stabilize
    sleep 3
    
    # Step 2: Get master node IDs
    log_info "Getting master node IDs..."
    declare -A master_node_ids
    for master in "${MASTERS[@]}"; do
        host="${master%%:*}"; port="${master##*:}"
        node_id=$(docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
            -h "$host" -p "$port" cluster myid 2>/dev/null | tr -d '\r')
        master_node_ids["$master"]="$node_id"
        log_info "Master $master has ID: $node_id"
    done
    
    # Step 3: Add each slave and assign to its corresponding master
    # Mapping: SLAVES[0] -> MASTERS[0], SLAVES[1] -> MASTERS[1], etc.
    for i in 0 1 2; do
        slave="${SLAVES[$i]}"
        master="${MASTERS[$i]}"
        master_id="${master_node_ids[$master]}"
        
        log_info "Adding slave $slave to cluster..."
        docker run --rm --network host -e REDISCLI_AUTH="$REDIS_PASSWORD" redis:7.4.7-alpine redis-cli \
            --cluster add-node "$slave" "${MASTERS[0]}" --cluster-slave --cluster-master-id "$master_id"
        
        sleep 1
    done
    
    log_success "Cluster created with specific master-slave assignments."
    log_info "Master-Slave mapping:"
    for i in 0 1 2; do
        log_info "  ${MASTERS[$i]} (master) <- ${SLAVES[$i]} (slave)"
    done
fi

echo ""
log_info "Process finished. You can check the cluster state with redis-cli --cluster info."
