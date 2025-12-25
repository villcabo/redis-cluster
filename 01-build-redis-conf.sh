#!/bin/sh

# Redis cluster configuration builder
# Builds Redis configuration files for cluster setup

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

if [ -z "$REDIS_PASSWORD" ]; then
    echo "[ERROR] REDIS_PASSWORD variable not set in .env file"
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

echo "[INFO] Configuration parameters:"
echo "  - IP: $IP"
echo "  - Password: [PROTECTED]"
echo "  - Port range: $PORT_START - $PORT_END"
echo ""

# Create conf directory if it doesn't exist
echo "[INFO] Creating configuration directory ./conf/"
mkdir -p ./conf

# Check if template file exists
if [ ! -f "./redis-cluster.tmpl" ]; then
    echo "[ERROR] Template file ./redis-cluster.tmpl not found"
    exit 1
fi

echo "[INFO] Template file found: ./redis-cluster.tmpl"
echo ""

# Generate configuration files
echo "[INFO] Starting configuration file generation..."
config_count=0

for port in $(seq $PORT_START $PORT_END); do
    config_file="./conf/redis-${port}.conf"
    echo "[INFO] Generating configuration for port $port..."
    echo "  - Target file: $config_file"
    
    # Create configuration file using template
    PORT=${port} IP=${IP} REDIS_PASSWORD=${REDIS_PASSWORD} \
        envsubst < ./redis-cluster.tmpl > "$config_file"
    
    # Verify file was created successfully
    if [ -f "$config_file" ]; then
        file_size=$(stat -f%z "$config_file" 2>/dev/null || stat -c%s "$config_file" 2>/dev/null)
        echo "  - ✓ Configuration created successfully (${file_size} bytes)"
        config_count=$((config_count + 1))
    else
        echo "  - ✗ Error creating configuration file"
        exit 1
    fi
done

echo ""
echo "[SUCCESS] Configuration generation completed!"
echo "  - Total configurations created: $config_count"
echo "  - Files location: ./conf/"
echo "  - Pattern: redis-{port}.conf"
echo ""
echo "[INFO] You can now start your Redis cluster with the generated configurations."
