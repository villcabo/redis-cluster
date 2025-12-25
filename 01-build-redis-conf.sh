#!/bin/bash

# Redis cluster configuration builder
# Builds Redis configuration files for cluster setup

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
    log_info "Loading environment variables from .env file..."
    . ./.env
    log_success "Environment variables loaded successfully"
else
    log_error ".env file not found. Please create it with required variables."
    exit 1
fi

# Validate required environment variables
if [ -z "$NODE_B1_IP" ] || [ -z "$NODE_B2_IP" ] || [ -z "$NODE_B3_IP" ]; then
    log_error "Node IP variables not set in .env file"
    log_error "Required: NODE_B1_IP, NODE_B2_IP, NODE_B3_IP"
    exit 1
fi

if [ -z "$REDIS_PASSWORD" ]; then
    log_error "REDIS_PASSWORD variable not set in .env file"
    exit 1
fi



log_info "Configuration parameters:"
echo "  - Node B1 IP: $NODE_B1_IP (redis1, redis4)"
echo "  - Node B2 IP: $NODE_B2_IP (redis2, redis5)"
echo "  - Node B3 IP: $NODE_B3_IP (redis3, redis6)"
echo "  - Password: [PROTECTED]"
echo "  - Port range: 7001 - 7006"
echo ""

# Create conf directory if it doesn't exist
log_info "Creating configuration directory ./conf/"
mkdir -p ./conf

# Check if template file exists
if [ ! -f "./redis-cluster.tmpl" ]; then
    log_error "Template file ./redis-cluster.tmpl not found"
    exit 1
fi

log_info "Template file found: ./redis-cluster.tmpl"
echo ""

# Generate configuration files
log_info "Starting configuration file generation..."
config_count=0

for port in $(seq 7001 7006); do
    config_file="./conf/redis-${port}.conf"
    log_info "Generating configuration for external port $port..."
    echo "  - Target file: $config_file"

    # Calculate bus port (external port + 10000)
    bus_port=$((port + 10000))

    # Determine which node IP to use based on port
    case $port in
        7001|7004) NODE_IP=$NODE_B1_IP ;;  # redis1, redis4 -> node b1
        7002|7005) NODE_IP=$NODE_B2_IP ;;  # redis2, redis5 -> node b2
        7003|7006) NODE_IP=$NODE_B3_IP ;;  # redis3, redis6 -> node b3
        *) log_error "Unexpected port $port"; exit 1 ;;
    esac

    echo "  - Using IP: $NODE_IP for node assignment"

    # Create configuration file using template
    NODE_IP=${NODE_IP} REDIS_PASSWORD=${REDIS_PASSWORD} EXTERNAL_PORT=${port} EXTERNAL_BUS_PORT=${bus_port} INTERNAL_PORT=${port} \
        envsubst < ./redis-cluster.tmpl > "$config_file"

    # Verify file was created successfully
    if [ -f "$config_file" ]; then
        file_size=$(stat -f%z "$config_file" 2>/dev/null || stat -c%s "$config_file" 2>/dev/null)
        echo "  - Configuration created successfully (${file_size} bytes)"
        config_count=$((config_count + 1))
    else
        echo "  - Error creating configuration file"
        exit 1
    fi
done

echo ""
log_success "Configuration generation completed!"
echo "  - Total configurations created: $config_count"
echo "  - Files location: ./conf/"
echo "  - Pattern: redis-{port}.conf"
echo ""
log_info "You can now start your Redis cluster with the generated configurations."
