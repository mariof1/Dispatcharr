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

# Pull latest changes from git and re-execute if script changed
pull_latest_code() {
    log_info "Pulling latest code from git..."
    cd "${SCRIPT_DIR}"
    
    # Check if this is a git repository
    if [ -d .git ]; then
        # Get current script hash
        local script_path="$0"
        local old_hash=""
        if [ -f "$script_path" ]; then
            old_hash=$(md5sum "$script_path" 2>/dev/null | cut -d' ' -f1)
        fi
        
        # Stash any local changes
        if ! git diff-index --quiet HEAD --; then
            log_warn "Local changes detected, stashing them..."
            git stash
        fi
        
        # Pull latest changes
        if git pull origin dev; then
            # Check if script changed
            local new_hash=""
            if [ -f "$script_path" ]; then
                new_hash=$(md5sum "$script_path" 2>/dev/null | cut -d' ' -f1)
            fi
            
            # If script changed, re-execute it
            if [ -n "$old_hash" ] && [ -n "$new_hash" ] && [ "$old_hash" != "$new_hash" ]; then
                log_info "Script updated! Re-executing with new version..."
                echo ""
                # Re-execute with same arguments
                if [[ $EUID -eq 0 ]]; then
                    exec bash "$script_path" "$@"
                else
                    exec bash "$script_path" "$@"
                fi
            fi
        else
            log_warn "Failed to pull from origin/dev, continuing with existing code"
        fi
    else
        log_warn "Not a git repository, skipping pull"
    fi
}

# Check if user is in docker group
check_docker_group() {
    local user="${SUDO_USER:-$USER}"
    
    if groups "$user" | grep -q '\bdocker\b'; then
        return 0
    else
        return 1
    fi
}

# Wrapper to run docker commands with proper permissions
run_docker() {
    local user="${SUDO_USER:-$USER}"
    
    if [[ $EUID -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
        # Running as sudo, use sg to run as user with docker group
        su - "$user" -c "cd '$PWD' && $*"
    else
        # Already running as correct user
        eval "$@"
    fi
}

# Check permissions and re-execute if needed
check_permissions() {
    local user="${SUDO_USER:-$USER}"
    
    # If not root and not in docker group, need sudo
    if [[ $EUID -ne 0 ]] && ! check_docker_group; then
        log_warn "Docker not installed or user not in docker group, will install..."
        log_info "Re-running with sudo..."
        exec sudo bash "$0" "$@"
    fi
}

# Install Docker
install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker is already installed ($(docker --version))"
        return 0
    fi

    log_info "Installing Docker..."
    
    # Ensure we're root for installation
    if [[ $EUID -ne 0 ]]; then
        log_error "Need root privileges to install Docker"
        exit 1
    fi
    
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
    local user="${SUDO_USER:-$USER}"
    
    # Skip if running as actual root (not sudo)
    if [[ "$user" == "root" ]]; then
        return 0
    fi
    
    if ! check_docker_group; then
        log_info "Adding user ${user} to docker group..."
        
        if [[ $EUID -ne 0 ]]; then
            log_error "Need root privileges to add user to docker group"
            exit 1
        fi
        
        usermod -aG docker "${user}"
        log_info "User ${user} added to docker group"
    else
        log_info "User ${user} is already in docker group"
    fi
}

# Create data directory
setup_directories() {
    log_info "Setting up directories..."
    mkdir -p "${DATA_DIR}"
    
    # Set appropriate permissions if running via sudo
    local user="${SUDO_USER:-$USER}"
    if [[ $EUID -eq 0 ]] && [[ "$user" != "root" ]]; then
        chown -R "${user}:${user}" "${DATA_DIR}"
    fi
}

# Stop existing containers
stop_existing_containers() {
    log_info "Checking for existing Dispatcharr containers..."
    
    cd "${DOCKER_DIR}"
    
    if run_docker "docker compose -f docker-compose.lxc.yml ps -q 2>/dev/null | grep -q ."; then
        log_info "Stopping existing containers..."
        run_docker "docker compose -f docker-compose.lxc.yml down"
    fi
}

# Pull latest images
pull_images() {
    log_info "Pulling latest Docker images..."
    cd "${DOCKER_DIR}"
    run_docker "docker compose -f docker-compose.lxc.yml pull"
}

# Start containers
start_containers() {
    log_info "Starting Dispatcharr containers..."
    cd "${DOCKER_DIR}"
    run_docker "docker compose -f docker-compose.lxc.yml up -d"
    
    log_info "Waiting for containers to be healthy..."
    sleep 5
}

# Get host IP address
get_host_ip() {
    # Try to get the primary IP address (not localhost)
    local ip=$(hostname -I | awk '{print $1}')
    
    # Fallback to ip command if hostname doesn't work
    if [ -z "$ip" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')
    fi
    
    # Final fallback to localhost
    if [ -z "$ip" ]; then
        ip="localhost"
    fi
    
    echo "$ip"
}

# Show status
show_status() {
    cd "${DOCKER_DIR}"
    echo ""
    log_info "Container status:"
    run_docker "docker compose -f docker-compose.lxc.yml ps"
    
    local host_ip=$(get_host_ip)
    
    echo ""
    log_info "==================================================="
    log_info "Dispatcharr is now running!"
    log_info "==================================================="
    log_info "Web Interface:    http://${host_ip}:9191"
    log_info "Frontend Dev:     http://${host_ip}:5656"
    log_info "WebSocket:        http://${host_ip}:8001"
    log_info "Redis Commander:  http://${host_ip}:8081"
    log_info "pgAdmin:          http://${host_ip}:8082"
    log_info "                  (admin@admin.com / admin)"
    log_info "==================================================="
    echo ""
    log_info "Useful commands:"
    log_info "  View logs:  cd ${DOCKER_DIR} && docker compose -f docker-compose.lxc.yml logs -f"
    log_info "  Stop:       cd ${DOCKER_DIR} && docker compose -f docker-compose.lxc.yml down"
    log_info "  Restart:    cd ${DOCKER_DIR} && docker compose -f docker-compose.lxc.yml restart"
    log_info "  Update:     cd ${SCRIPT_DIR} && ./lxc_setup.sh"
    echo ""
}

# Main execution
main() {
    log_info "🚀 Starting Dispatcharr LXC Setup..."
    echo ""
    
    # Check permissions first (will re-exec with sudo if needed)
    check_permissions
    
    # Pull latest code
    pull_latest_code
    
    # Install and configure
    install_docker
    setup_docker_permissions
    setup_directories
    stop_existing_containers
    pull_images
    start_containers
    show_status
    
    echo ""
    log_info "✅ Setup complete! Dispatcharr is ready to use! 🎉"
    
    local user="${SUDO_USER:-$USER}"
    if [[ $EUID -eq 0 ]] && [[ "$user" != "root" ]]; then
        echo ""
        log_warn "Note: Future updates can be run without sudo:"
        log_info "  Just run: ./lxc_setup.sh"
    fi
}

# Run main function
main "$@"
