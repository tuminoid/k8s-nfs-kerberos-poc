#!/usr/bin/env bash

# Ubuntu 24.04 Kubernetes Node Prerequisites Setup
# Run this to install Docker, containerd, kubectl, and prepare the node for Kubernetes
# Usage: ./install-k8s.sh [kdc_server_ip] [nfs_server_ip] [k8s_version]

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Color print functions
print_red() { echo -e "${RED}$*${NC}"; }
print_green() { echo -e "${GREEN}$*${NC}"; }
print_yellow() { echo -e "${YELLOW}$*${NC}"; }

# Auto-detect IP address from ens3 interface
HOST_IP=$(ip addr show ens3 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
if [[ -z "${HOST_IP:-}" ]]; then
    print_red "ERROR: Could not detect IP address from ens3 interface"
    exit 1
fi

# Parameters - KDC and NFS IPs are required for multi-server setup
if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
    print_red "ERROR: KDC and NFS server IPs are required"
    echo "Usage: $0 <kdc_server_ip> <nfs_server_ip> [k8s_version]"
    exit 1
fi

KDC_SERVER_IP="$1"
NFS_SERVER_IP="$2"
K8S_VERSION="${3:-1.32}"

# Expand IPs to full nip.io hostnames
KDC_HOSTNAME="kdc-${KDC_SERVER_IP}.nip.io"
NFS_HOSTNAME="nfs-${NFS_SERVER_IP}.nip.io"

print_yellow "=== Setting up Kubernetes Node Prerequisites (Multi-Server) ==="
echo "K8S IP: ${HOST_IP}"
echo "KDC Server IP: ${KDC_SERVER_IP} -> ${KDC_HOSTNAME}"
echo "NFS Server IP: ${NFS_SERVER_IP} -> ${NFS_HOSTNAME}"

# Configuration
K8S_HOSTNAME="k8s-${HOST_IP}.nip.io"
REALM="EXAMPLE.COM"

print_yellow "=== Setting up Kubernetes Node Prerequisites ==="
echo "Detected Host IP: ${HOST_IP}"
echo "K8s Hostname: ${K8S_HOSTNAME}"
echo "KDC Hostname: ${KDC_HOSTNAME}"
echo "NFS Hostname: ${NFS_HOSTNAME}"
echo "Kubernetes Version: ${K8S_VERSION}"

# Update system
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get upgrade -y

# Install required packages for Kubernetes
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gpg \
    nfs-common \
    krb5-user \
    keyutils \
    golang-go

# Add Kubernetes signing key
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

# Install containerd, docker.io, and Kubernetes tools
apt-get update
apt-get install -y containerd docker.io kubelet kubeadm kubectl
kubectl completion bash >/etc/bash_completion.d/kubectl

# Configure and start Docker
systemctl enable --now docker
usermod -aG docker ubuntu

# Configure containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

# configure nri for containerd
# https://github.com/containerd/containerd/blob/main/docs/NRI.md#enabling-nri-support-in-containerd
# Enable NRI support by changing disable = true to disable = false only for the NRI plugin
sed -i '/\[plugins\."io\.containerd\.nri\.v1\.nri"\]/,/^$/s/disable = true/disable = false/' /etc/containerd/config.toml

# Enable SystemdCgroup for containerd
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Disable swap (required for Kubernetes)
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load required kernel modules
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Configure system settings for Kubernetes
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# Install NFS and Kerberos client packages locally
print_yellow "Installing NFS and Kerberos client packages locally..."
apt-get install -y \
    nfs-common \
    keyutils \
    rpcbind \
    libkrb5-3 \
    libgssapi-krb5-2 \
    >/dev/null 2>&1

# Configure NFSv4 domain for proper user mapping (ensure it persists)
print_yellow "Configuring NFSv4 domain mapping..."
cat > /etc/idmapd.conf << EOF
[General]
Verbosity = 0
Domain = example.com

[Mapping]
Nobody-User = nobody
Nobody-Group = nogroup
EOF

# Ensure kernel modules load on boot
cat > /etc/modules-load.d/nfs-kerberos.conf << EOF
# NFS Kerberos kernel modules - auto-loaded on boot
auth_rpcgss
rpcsec_gss_krb5
EOF

# explicitly set some gssd options
# context-timeout is 1800 = 30 min, same as ticket lifetime
sed -i \
    -e 's/^# context-timeout=0/context-timeout=1800/' \
    -e 's/^# rpc-timeout=5/rpc-timeout=10/' \
    -e 's/^# upcall-timeout=30/upcall-timeout=60/' \
    -e 's/^# use-machine-creds=1/use-machine-creds=1/' \
    -e "s/^# preferred-realm=/preferred-realm=${REALM}/" \
    /etc/nfs.conf
cat >> /etc/nfs.conf << EOF
[nfsmount]
retry=2
EOF

# Load kernel modules now
modprobe auth_rpcgss || true
modprobe rpcsec_gss_krb5 || true

# Set up RPC pipefs and ensure it mounts on boot
mkdir -p /var/lib/nfs/rpc_pipefs
mount -t rpc_pipefs sunrpc /var/lib/nfs/rpc_pipefs || true

# Add RPC pipefs to fstab for persistent mounting
if ! grep -q "rpc_pipefs" /etc/fstab; then
    echo "sunrpc /var/lib/nfs/rpc_pipefs rpc_pipefs defaults 0 0" >> /etc/fstab
fi

# Enable and start required services (enable ensures auto-start on boot)
systemctl enable --now rpcbind

# Note: rpc-gssd and nfs-idmapd are "static" services - they're automatically
# started when needed by NFS operations. We ensure the NFS client target is enabled.
systemctl enable --now nfs-client.target

# Start the static services now for immediate availability
systemctl start rpc-gssd nfs-idmapd &>/dev/null || true

# create script to authenticate system credentials
# Create the script file
cat > /usr/local/bin/kerberos-system-auth.sh << 'EOF'
#!/usr/bin/env bash

set -euo pipefail

KEYTAB_FILE="/etc/krb5.keytab"
LOG_TAG="kerberos-system-creds"
export KRB5CCNAME=${KRB5CCNAME:-"FILE:/tmp/krb5cc_0"}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"
}

if [[ ! -f "${KEYTAB_FILE}" ]]; then
    log "ERROR: Keytab file ${KEYTAB_FILE} not found"
    exit 1
fi

log "Starting Kerberos system authentication"
log "Using keytab: ${KEYTAB_FILE}"

# List what's in the keytab for debugging
log "Keytab contents:"
klist -k "${KEYTAB_FILE}" | while read line; do
    log "  $line"
done

# Extract NFS principals and authenticate
principals=$(klist -k "${KEYTAB_FILE}" | grep 'nfs/' | awk 'NF>1 {print $2}' | sort -u)

if [[ -z "${principals}" ]]; then
    log "ERROR: No NFS principals found in keytab"
    log "Available principals:"
    klist -k "${KEYTAB_FILE}" | grep -v "^Keytab" | grep -v "^----" | grep -v "^KVNO" | while read line; do
        log "  $line"
    done
    exit 1
fi

# Authenticate each principal
echo "${principals}" | while IFS= read -r principal; do
    if [[ -n "${principal}" ]]; then
        log "Processing principal: ${principal}"

        # First try to renew existing credentials
        if kinit -R "${principal}" 2>/dev/null; then
            log "✓ Successfully renewed credentials for: ${principal}"
        else
            log "Renewal failed, re-authenticating with keytab for: ${principal}"
            if kinit -k -t "${KEYTAB_FILE}" "${principal}"; then
                log "✓ Successfully authenticated with keytab: ${principal}"
            else
                log "✗ Failed to authenticate: ${principal}"
            fi
        fi
    fi
done

log "Kerberos system authentication completed"

# Verify we have tickets
if klist &>/dev/null; then
    log "✓ Active Kerberos tickets:"
    klist | while read line; do
        log "  $line"
    done
else
    log "✗ No active Kerberos tickets found"
    exit 1
fi

# flush the rpc gssd cache to ensure it picks up new creds
echo $(date +%s) > /proc/net/rpc/auth.rpcsec.context/flush
EOF
chmod +x /usr/local/bin/kerberos-system-auth.sh

# Create system credential service template (will be customized by deploy script)
print_yellow "Setting up Kerberos system credentials service and timer..."
cat > /etc/systemd/system/kerberos-system-creds.service << EOF
[Unit]
Description=Initialize Kerberos System Credentials for NFS
After=network-online.target rpc-gssd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kerberos-system-auth.sh
Environment=KRB5CCNAME=FILE:/tmp/krb5cc_0
User=root
EOF

# Create timer to run every 20 minutes (tickets expire after 30min max)
cat > /etc/systemd/system/kerberos-system-creds.timer << EOF
[Unit]
Description=Timer for Kerberos System Credentials Renewal
Requires=kerberos-system-creds.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=4min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

# add -n to rpc.gssd
sed -i -e '/^ExecStart=/ s/$/ -n/' /usr/lib/systemd/system/rpc-gssd.service

systemctl daemon-reload
systemctl enable --now kerberos-system-creds.timer
print_green "✓ System credentials service and timer configured"

# Verify system credential service is configured
sleep 2
if systemctl is-enabled --quiet kerberos-system-creds.timer 2>/dev/null; then
    print_green "✓ System credentials service configured and enabled"
else
    print_red "Warning: System credentials service not properly configured"
fi
print_green "✓ Local node configured for NFS with Kerberos support"

# Create keytabs directory and clean up any existing Kerberos files
mkdir -p /etc/keytabs
rm -f /etc/krb5.conf
rm -f /etc/keytabs/*.keytab
echo "Downloading krb5.conf from http://${KDC_HOSTNAME}:8080/"
wget -O /etc/krb5.conf "http://${KDC_HOSTNAME}:8080/krb5.conf" || {
    print_red "ERROR: Failed to download krb5.conf from KDC"
    echo "Make sure the KDC is running and accessible at ${KDC_HOSTNAME}:8080"
    exit 1
}

print_green "Kubernetes Node Prerequisites Setup Complete"

print_yellow "\nReboot the node before deploying Kubernetes:"
print_yellow "make deploy KDC=${KDC_SERVER_IP} NFS=${NFS_SERVER_IP}"
