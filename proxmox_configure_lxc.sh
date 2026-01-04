#!/usr/bin/env bash

# This script needs to be run ON THE PROXMOX HOST, not inside the LXC
# It configures the LXC container to support Docker properly

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check if running on Proxmox host
if ! command -v pct &> /dev/null; then
    log_error "This script must be run on the Proxmox host, not inside the LXC!"
    log_info "Please copy this script to your Proxmox host and run it there."
    exit 1
fi

# Get LXC ID
echo ""
read -p "Enter your LXC container ID (e.g., 100): " CTID

if [ -z "$CTID" ]; then
    log_error "Container ID cannot be empty"
    exit 1
fi

# Check if container exists
if ! pct status "$CTID" &> /dev/null; then
    log_error "Container $CTID does not exist"
    exit 1
fi

LXC_CONF="/etc/pve/lxc/${CTID}.conf"

log_info "Configuring LXC container ${CTID} for Docker support..."

# Backup original config
cp "$LXC_CONF" "${LXC_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
log_info "Original config backed up"

# Check if already configured
if grep -q "lxc.apparmor.profile: unconfined" "$LXC_CONF"; then
    log_warn "Container already appears to be configured for Docker"
    read -p "Reconfigure anyway? (y/N): " RECONF
    if [[ ! "$RECONF" =~ ^[Yy]$ ]]; then
        log_info "Skipping configuration"
        exit 0
    fi
fi

# Add Docker support configurations
log_info "Adding Docker configurations to LXC..."

cat >> "$LXC_CONF" << 'EOF'

# Docker support configurations
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
EOF

log_info "Configuration added successfully!"

# Ask if container should be restarted
echo ""
log_warn "The container needs to be restarted for changes to take effect."
read -p "Restart container ${CTID} now? (y/N): " RESTART

if [[ "$RESTART" =~ ^[Yy]$ ]]; then
    log_info "Stopping container ${CTID}..."
    pct stop "$CTID"
    
    log_info "Starting container ${CTID}..."
    pct start "$CTID"
    
    log_info "Container restarted successfully!"
else
    log_warn "Please restart the container manually: pct stop ${CTID} && pct start ${CTID}"
fi

echo ""
log_info "==================================================="
log_info "LXC container ${CTID} is now configured for Docker!"
log_info "==================================================="
log_info "You can now run the lxc_setup.sh script inside the container."
echo ""
