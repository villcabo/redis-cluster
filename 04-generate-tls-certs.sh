#!/bin/bash

# Generate TLS certificates for OAuth2 Proxy HTTPS configuration

# Color configuration for output
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
CYAN=$(tput setaf 6)
WHITE=$(tput setaf 7)
BOLD=$(tput bold)
NC=$(tput sgr0) # No Color

# Logging functions
log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_header() {
    echo -e "\n${BOLD}${BLUE}$1${NC}"
    echo -e "${BLUE}$(printf '%.0s=' {1..60})${NC}"
}

# Load variables from .env file
load_env_variables() {
    if [ -f ".env" ]; then
        log_info "Loading configuration from .env..."
        # Load variables same way as in 03-test-redis-cluster.sh
        NODE_B1_IP=$(grep "^NODE_B1_IP=" .env | cut -d'=' -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"'"'"')')

        if [ -z "$NODE_B1_IP" ]; then
            log_warning "NODE_B1_IP not found in .env file. Using default."
            NODE_B1_IP="192.168.1.100"
        fi
        log_success "Environment variables loaded"
    else
        log_warning ".env file not found. Using default values."
        NODE_B1_IP="192.168.1.100"
    fi
}

# Check if openssl is installed
check_openssl() {
    if ! command -v openssl &> /dev/null; then
        log_error "OpenSSL is not installed. Please install it first:"
        log_info "Ubuntu/Debian: apt-get install openssl"
        log_info "RHEL/CentOS: yum install openssl"
        exit 1
    fi
    log_success "OpenSSL is available: $(openssl version)"
}

# Create necessary directories
create_directories() {
    log_info "Creating certificate directories..."
    mkdir -p certs
    chmod 700 certs
    log_success "Directories created: ./certs/"
}

# Generate basic self-signed certificate
generate_basic_certificate() {
    log_header "Generating Basic Self-Signed Certificate"

    # Use first IP from .env as certificate CN
    SERVER_IP=${NODE_B1_IP:-192.168.1.100}

    log_info "Using server IP: ${SERVER_IP}"
    log_info "Generating certificate valid for any domain..."
    log_info "Duration: 10 years (3650 days)"

    openssl req -x509 -newkey rsa:4096 -keyout certs/oauth2-proxy.key -out certs/oauth2-proxy.crt \
        -days 3650 -nodes \
        -subj "/C=BO/ST=Bolivia/L=La Paz/O=Sintesis S.A./OU=IT/CN=${SERVER_IP}"

    if [ $? -eq 0 ]; then
        log_success "Basic certificate generated successfully"
        log_info "Certificate: ./certs/oauth2-proxy.crt"
        log_info "Private key: ./certs/oauth2-proxy.key"
        log_info "CN (Common Name): ${SERVER_IP}"
    else
        log_error "Error generating certificate"
        exit 1
    fi
}

# Main function
main() {
    log_header "TLS Certificate Generator for OAuth2 Proxy"

    load_env_variables
    check_openssl
    create_directories
    generate_basic_certificate

    log_success "\nTLS certificate generated successfully!"
}

# Execute main function
main "$@"
