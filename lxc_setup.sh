#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="${SCRIPT_DIR}/docker"
DATA_DIR="${DOCKER_DIR}/data"

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running with sudo/root
check_permissions() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run with sudo or as root"
        exit 1
    fi
}

# Install Docker
install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker is already installed ($(docker --version))"
        return 0
    fi

    log_info "Installing Docker..."
    
    # Install prerequisites
    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Set up the repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker Engine
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Start and enable Docker
    systemctl enable docker
    systemctl start docker

    log_info "Docker installed successfully!"
}

# Add current user to docker group (if not root)
setup_docker_permissions() {
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        log_info "Adding user ${SUDO_USER} to docker group..."
        usermod -aG docker "${SUDO_USER}"
        log_warn "User ${SUDO_USER} added to docker group. You may need to log out and back in for this to take effect."
    fi
}

# Create data directory
setup_directories() {
    log_info "Setting up directories..."
    mkdir -p "${DATA_DIR}"
    
    # Set appropriate permissions if running via sudo
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "${SUDO_USER}:${SUDO_USER}" "${DATA_DIR}"
    fi
}

# Stop existing containers
stop_existing_containers() {
    log_info "Checking for existing Dispatcharr containers..."
    
    cd "${DOCKER_DIR}"
    
    if docker compose -f docker-compose.dev.yml ps -q 2>/dev/null | grep -q .; then
        log_info "Stopping existing containers..."
        docker compose -f docker-compose.dev.yml down
    fi
}

# Pull latest images
pull_images() {
    log_info "Pulling latest Docker images..."
    cd "${DOCKER_DIR}"
    docker compose -f docker-compose.dev.yml pull
}

# Start containers
start_containers() {
    log_info "Starting Dispatcharr containers..."
    cd "${DOCKER_DIR}"
    docker compose -f docker-compose.dev.yml up -d
    
    log_info "Waiting for containers to be healthy..."
    sleep 5
}

# Show status
show_status() {
    cd "${DOCKER_DIR}"
    echo ""
    log_info "Container status:"
    docker compose -f docker-compose.dev.yml ps
    
    echo ""
    log_info "==================================================="
    log_info "Dispatcharr is now running!"
    log_info "==================================================="
    log_info "Web Interface:    http://localhost:9191"
    log_info "Frontend Dev:     http://localhost:5656"
    log_info "WebSocket:        http://localhost:8001"
    log_info "Redis Commander:  http://localhost:8081"
    log_info "pgAdmin:          http://localhost:8082"
    log_info "                  (admin@admin.com / admin)"
    log_info "==================================================="
    echo ""
    log_info "To view logs: cd ${DOCKER_DIR} && docker compose -f docker-compose.dev.yml logs -f"
    log_info "To stop:      cd ${DOCKER_DIR} && docker compose -f docker-compose.dev.yml down"
    log_info "To restart:   cd ${DOCKER_DIR} && docker compose -f docker-compose.dev.yml restart"
    echo ""
}

# Main execution
main() {
    log_info "Starting Dispatcharr LXC Setup..."
    echo ""
    
    check_permissions
    install_docker
    setup_docker_permissions
    setup_directories
    stop_existing_containers
    pull_images
    start_containers
    show_status
    
    log_info "Setup complete! 🎉"
}

# Run main function
main "$@"
