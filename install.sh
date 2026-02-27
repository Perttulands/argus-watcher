#!/usr/bin/env bash
set -euo pipefail

# install.sh — Install Argus as a systemd service
# Idempotent — safe to re-run to update configuration.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Generate service file from template using current user/home
INSTALL_USER="${SUDO_USER:-$USER}"
INSTALL_HOME="$(eval echo ~"$INSTALL_USER")"
SERVICE_FILE="${SCRIPT_DIR}/argus.service.generated"
SYSTEMD_DIR="/etc/systemd/system"
ARGUS_ENV_DIR="/etc/argus"
SYSTEM_ENV_FILE="${ARGUS_ENV_DIR}/argus.env"
ENV_FILE="${SCRIPT_DIR}/argus.env"
ARGUS_STATE_DIR="${ARGUS_STATE_DIR:-$HOME/athena/state/argus}"

echo "===== Argus Installation ====="
echo ""

# Check if running with appropriate permissions
if [[ ! -w "$SYSTEMD_DIR" ]] && [[ $EUID -ne 0 ]]; then
    echo "This script requires sudo to install the systemd service."
    echo "You will be prompted for your password."
    echo ""
fi

# Verify required dependencies
echo "Checking dependencies..."
local_missing=()
for cmd in claude jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
        local_missing+=("$cmd")
    fi
done
if [[ ${#local_missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required commands: ${local_missing[*]}"
    echo "Install them before proceeding."
    exit 1
fi
echo "  Dependencies OK: claude, jq, curl"

# Make scripts executable
echo "Making scripts executable..."
chmod +x "${SCRIPT_DIR}/argus.sh"
chmod +x "${SCRIPT_DIR}/collectors.sh"
chmod +x "${SCRIPT_DIR}/actions.sh"

# Check for environment file
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Environment file not found: $ENV_FILE"
    echo ""
    echo "Create it from the example:"
    echo "  cp argus.env.example argus.env"
    echo "  nano argus.env  # Add your TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID"
    echo ""
    exit 1
fi

# Create directories
echo "Creating directories..."
mkdir -p "${SCRIPT_DIR}/logs"
mkdir -p "$ARGUS_STATE_DIR"

# Install environment file (contains secrets — mode 600)
echo "Installing environment file..."
sudo mkdir -p "$ARGUS_ENV_DIR"
sudo cp "$ENV_FILE" "$SYSTEM_ENV_FILE"
sudo chmod 600 "$SYSTEM_ENV_FILE"
sudo chown root:root "$SYSTEM_ENV_FILE"

# Generate and install systemd service from template
echo "Generating systemd service for user ${INSTALL_USER} (home: ${INSTALL_HOME})..."
cat > "$SERVICE_FILE" <<UNIT_EOF
[Unit]
Description=Argus Ops Watchdog
After=network-online.target
Wants=network-online.target
Documentation=https://github.com/perttu/argus

[Service]
Type=simple
User=${INSTALL_USER}
Group=${INSTALL_USER}
WorkingDirectory=${SCRIPT_DIR}
Environment="PATH=${INSTALL_HOME}/.local/bin:${INSTALL_HOME}/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=-${SCRIPT_DIR}/argus.env
ExecStart=/usr/bin/bash -lc './argus.sh'
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal
SyslogIdentifier=argus

# Resource limits
MemoryMax=1G
MemoryHigh=768M

TimeoutStopSec=30

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=false
ReadWritePaths=${SCRIPT_DIR}/logs ${SCRIPT_DIR}/state ${INSTALL_HOME}/.openclaw-athena

[Install]
WantedBy=multi-user.target
UNIT_EOF

echo "Installing systemd service..."
sudo cp "$SERVICE_FILE" "${SYSTEMD_DIR}/argus.service"
rm -f "$SERVICE_FILE"

# Reload systemd daemon
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

# Enable service
echo "Enabling argus service..."
sudo systemctl enable argus.service

# Restart if already running (update scenario), otherwise ask
if systemctl is-active argus.service &>/dev/null; then
    echo ""
    echo "Argus is currently running. Restarting to apply changes..."
    sudo systemctl restart argus.service
    sleep 2
    echo "Service restarted."
else
    echo ""
    read -p "Start Argus service now? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Starting argus service..."
        sudo systemctl start argus.service
        sleep 2
        echo "Service started."
    else
        echo "Skipping. Start manually: sudo systemctl start argus"
    fi
fi

echo ""
sudo systemctl status argus.service --no-pager -l 2>/dev/null || true # REASON: informational status display; should not fail the installer.

echo ""
echo "===== Installation Complete ====="
echo ""
echo "Commands:"
echo "  sudo systemctl status argus           # Service status"
echo "  sudo journalctl -u argus -f           # Follow systemd logs"
echo "  tail -f ${SCRIPT_DIR}/logs/argus.log  # Follow app logs"
echo "  ${SCRIPT_DIR}/argus.sh --once         # Test single cycle"
echo ""
