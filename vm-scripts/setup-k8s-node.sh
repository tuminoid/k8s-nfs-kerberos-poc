#!/usr/bin/env bash

# Ubuntu 24.04 Kubernetes Node Prerequisites Setup
# Run this to install Docker, containerd, kubectl, and prepare the node for Kubernetes
# Usage: ./setup-k8s-node.sh [kdc_server_ip] [nfs_server_ip] [k8s_version]

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

# Parameters - if KDC/NFS IPs are provided, use them; otherwise assume single-node setup
KDC_SERVER_IP="${1:-$HOST_IP}"
NFS_SERVER_IP="${2:-$HOST_IP}"
K8S_VERSION="${3:-1.32}"

# Expand IPs to full nip.io hostnames
KDC_HOSTNAME="kdc-${KDC_SERVER_IP}.nip.io"
NFS_HOSTNAME="nfs-${NFS_SERVER_IP}.nip.io"

if [[ "${KDC_SERVER_IP}" != "${HOST_IP}" ]] || [[ "${NFS_SERVER_IP}" != "${HOST_IP}" ]]; then
    print_yellow "=== Setting up Kubernetes Node Prerequisites (Multi-Server) ==="
    echo "K8S IP: ${HOST_IP}"
    echo "KDC Server IP: ${KDC_SERVER_IP} -> ${KDC_HOSTNAME}"
    echo "NFS Server IP: ${NFS_SERVER_IP} -> ${NFS_HOSTNAME}"
else
    print_yellow "=== Setting up Kubernetes Node Prerequisites (Single-Node) ==="
    echo "Host IP: ${HOST_IP}"
    echo "KDC/NFS Hostname: ${KDC_HOSTNAME} / ${NFS_HOSTNAME}"
fi

# Configuration
K8S_HOSTNAME="k8s-${HOST_IP}.nip.io"
LOCAL_USERS="${LOCAL_USERS:-false}"

print_yellow "=== Setting up Kubernetes Node Prerequisites ==="
echo "Detected Host IP: ${HOST_IP}"
echo "K8s Hostname: ${K8S_HOSTNAME}"
echo "KDC Hostname: ${KDC_HOSTNAME}"
echo "NFS Hostname: ${NFS_HOSTNAME}"
echo "Kubernetes Version: ${K8S_VERSION}"
echo "Using Local Users: ${LOCAL_USERS}"

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
    heimdal-kcm > /dev/null 2>&1

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

# Load kernel modules now
modprobe auth_rpcgss || true
modprobe rpcsec_gss_krb5 || true

# Enable and start required services (enable ensures auto-start on boot)
systemctl enable --now rpcbind

# Note: rpc-gssd and nfs-idmapd are "static" services - they're automatically
# started when needed by NFS operations. We ensure the NFS client target is enabled.
systemctl enable --now nfs-client.target

# Start the static services now for immediate availability
systemctl start rpc-gssd nfs-idmapd &>/dev/null || true

# Set up RPC pipefs and ensure it mounts on boot
mkdir -p /var/lib/nfs/rpc_pipefs
mount -t rpc_pipefs sunrpc /var/lib/nfs/rpc_pipefs || true

# Add RPC pipefs to fstab for persistent mounting
if ! grep -q "rpc_pipefs" /etc/fstab; then
    echo "sunrpc /var/lib/nfs/rpc_pipefs rpc_pipefs defaults 0 0" >> /etc/fstab
fi

# Create systemd service for KCM daemon (persistent across reboots)
print_yellow "Setting up KCM daemon as systemd service..."
cat > /etc/systemd/system/kcm.service << EOF
[Unit]
Description=Kerberos Credentials Manager
After=network.target

[Service]
Type=forking
ExecStart=/usr/sbin/kcm --detach
PIDFile=/var/run/kcm.pid
Restart=always
RestartSec=5
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable KCM service
systemctl daemon-reload
systemctl enable --now kcm

# Create system credential service template (will be customized by deploy script)
print_yellow "Setting up Kerberos system credentials service template..."
cat > /etc/systemd/system/kerberos-system-creds.service << EOF
[Unit]
Description=Initialize Kerberos System Credentials for NFS
After=network-online.target rpc-gssd.service kcm.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "if [ -f /etc/krb5.keytab ]; then /usr/bin/kinit -k -t /etc/krb5.keytab \$(klist -k /etc/krb5.keytab | grep nfs/ | head -1 | awk '"'"'{print \$2}'"'"'); fi"
Environment=KRB5CCNAME=FILE:/tmp/krb5cc_0
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kerberos-system-creds

# Verify KCM socket exists
sleep 2
if ls -la /var/run/ | grep -q kcm; then
    print_green "✓ KCM daemon service enabled and socket available"
else
    print_red "Warning: KCM socket not found - may need manual restart"
fi

print_green "✓ System credentials service template configured"

print_green "✓ Local node configured for NFS with Kerberos support"

# Download Kerberos configuration from KDC
print_yellow "Downloading Kerberos configuration from KDC..."
# Clean up any existing Kerberos files first
rm -f /etc/krb5.conf
rm -f /etc/keytabs/*.keytab
echo "Downloading krb5.conf from http://${KDC_HOSTNAME}:8080/"
wget -O /etc/krb5.conf "http://${KDC_HOSTNAME}:8080/krb5.conf" || {
    print_red "ERROR: Failed to download krb5.conf from KDC"
    echo "Make sure the KDC is running and accessible at ${KDC_HOSTNAME}:8080"
    exit 1
}

# if we have static local users, do this
if [[ "${LOCAL_USERS}" = true ]]; then
    echo "Downloading user keytabs from KDC..."
    mkdir -p /etc/keytabs
    for user in user10002 user10003 user10004; do
        wget -O "/etc/keytabs/${user}.keytab" "http://${KDC_HOSTNAME}:8080/keytabs/${user}.keytab" || {
            print_red "ERROR: Failed to download ${user}.keytab from KDC"
            exit 1
        }
    done

    # Set appropriate permissions for user keytabs
    echo "Setting keytab permissions..."
    for user in user10002 user10003 user10004; do
        # Extract user ID (e.g., 10002 from user10002) and calculate group ID (e.g., 5002)
        user_id=${user#user}
        group_id=$((user_id - 5000))  # 10002 -> 5002, 10003 -> 5003, etc.
        chown "${user_id}:${group_id}" "/etc/keytabs/${user}.keytab"
        chmod 600 "/etc/keytabs/${user}.keytab"
    done
    print_green "✓ Kerberos configuration downloaded successfully"
else
    # we will use NRI to download the keytabs
    print_yellow "Skipping user keytab download for non-local users setup"
fi

# Extract KDC and NFS server IPs from hostnames
KDC_IP=$(echo "${KDC_HOSTNAME}" | sed 's/kdc-\([0-9.]*\)\.nip\.io/\1/')
NFS_IP=$(echo "${NFS_HOSTNAME}" | sed 's/nfs-\([0-9.]*\)\.nip\.io/\1/')

# Kubernetes specific ports - lets not mess with ufw for no reason
if false; then
    # Configure firewall for Kubernetes node
    print_yellow "Configuring UFW firewall for Kubernetes node..."
    ufw --force enable

    ufw allow 6443/tcp       # Kubernetes API server
    ufw allow 2379:2380/tcp  # etcd server client API
    ufw allow 10250/tcp      # Kubelet API
    ufw allow 10259/tcp      # kube-scheduler
    ufw allow 10257/tcp      # kube-controller-manager
    ufw allow 22/tcp         # SSH

    # Container networking
    ufw allow from 10.244.0.0/16    # Pod network (Flannel default)
    ufw allow from 10.96.0.0/12     # Service network (K8s default)

    # Allow access to specific servers
    if [[ "${KDC_IP}" != "${KDC_HOSTNAME}" ]]; then
        echo "Allowing outbound access to KDC server: ${KDC_IP}"
        ufw allow out to "${KDC_IP}"
    fi

    if [[ "${NFS_IP}" != "${NFS_HOSTNAME}" ]]; then
        echo "Allowing outbound access to NFS server: ${NFS_IP}"
        ufw allow out to "${NFS_IP}"
    fi

    print_green "✓ Firewall configured for Kubernetes node"
fi

print_green "Kubernetes Node Prerequisites Setup Complete"

print_yellow "\nReboot the node before deploying Kubernetes:"
print_yellow "make deploy KDC=${KDC_SERVER_IP} NFS=${NFS_SERVER_IP}"
