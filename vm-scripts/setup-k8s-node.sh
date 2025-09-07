#!/usr/bin/env bash

# Ubuntu 24.04 Kubernetes Node Prerequisites Setup
# Run this to install Docker, containerd, kubectl, and prepare the node for Kubernetes

set -eu

# Auto-detect IP address from ens3 interface
HOST_IP=$(ip addr show ens3 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Could not detect IP address from ens3 interface"
    exit 1
fi

# Configuration
K8S_VERSION="${1:-1.32}"          # Kubernetes version

echo "=== Setting up Kubernetes Node Prerequisites ==="
echo "Detected Host IP: ${HOST_IP}"

# Update system
apt-get update && apt-get upgrade -y

# Install required packages for Kubernetes
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gpg \
    nfs-common \
    krb5-user \
    keyutils

# Add Kubernetes signing key
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

# Install containerd, docker.io, and Kubernetes tools
apt-get update
apt-get install -y containerd docker.io kubelet kubeadm kubectl

# Configure and start Docker
systemctl start docker
systemctl enable docker
usermod -aG docker "${USER}"

# Configure containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Install NFS and Kerberos client packages locally
echo -e "${YELLOW}Installing NFS and Kerberos client packages locally...${NC}"
apt-get update > /dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nfs-common \
    keyutils \
    rpcbind \
    libkrb5-3 \
    libgssapi-krb5-2 \
    heimdal-kcm > /dev/null 2>&1

# Enable and start required services
systemctl enable rpcbind > /dev/null 2>&1
systemctl start rpcbind > /dev/null 2>&1

# Load kernel modules
modprobe auth_rpcgss > /dev/null 2>&1 || true
modprobe rpcsec_gss_krb5 > /dev/null 2>&1 || true

# Set up RPC pipefs
mkdir -p /var/lib/nfs/rpc_pipefs
mount -t rpc_pipefs sunrpc /var/lib/nfs/rpc_pipefs 2>/dev/null || true

# Start KCM daemon for credential sharing
echo -e "${YELLOW}Starting KCM daemon for credential sharing...${NC}"
pkill kcm || true
/usr/sbin/kcm --detach > /dev/null 2>&1
sleep 2

# Verify KCM socket exists
if ls -la /var/run/ | grep -q kcm; then
    echo -e "${GREEN}✓ KCM daemon started and socket available${NC}"
else
    echo -e "${RED}Warning: KCM socket not found${NC}"
fi

echo -e "${GREEN}✓ Local node configured for NFS with Kerberos support${NC}"

echo ""
echo "=================================================================="
echo "Kubernetes Node Prerequisites Setup Complete"
echo "=================================================================="
