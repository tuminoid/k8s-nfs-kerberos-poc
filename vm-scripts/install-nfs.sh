#!/usr/bin/env bash

# Run this on a dedicated VM for the NFS server
# Usage: ./install-nfs.sh <kdc_hostname> [k8s_hostname]

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m'

# Color print functions
print_red() { echo -e "${RED}$*${NC}"; }
print_green() { echo -e "${GREEN}$*${NC}"; }
print_yellow() { echo -e "${YELLOW}$*${NC}"; }

if [[ "$(id -u)" -ne 0 ]]; then
    print_red "ERROR: This script must be run as root"
    exit 1
fi

HOST_IP=$(ip addr show ens3 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
if [[ -z "${HOST_IP:-}" ]]; then
    print_red "ERROR: Could not detect IP address from ens3 interface"
    exit 1
fi

# Parameters - if KDC IP is provided, use it; otherwise assume single-node setup
KDC_SERVER_IP="${1:-$HOST_IP}"
K8S_SERVER_IP="${2:-$HOST_IP}"

# Expand IPs to full nip.io hostnames
KDC_HOSTNAME="kdc-${KDC_SERVER_IP}.nip.io"
NFS_HOSTNAME="nfs-${HOST_IP}.nip.io"
K8S_HOSTNAME="k8s-${K8S_SERVER_IP}.nip.io"

# Configuration using nip.io
REALM="EXAMPLE.COM"
DOMAIN="example.com"

if [[ "${KDC_SERVER_IP}" != "${HOST_IP}" ]]; then
    echo "=== Installing NFS Server with Kerberos on Ubuntu 24.04 (Multi-Server) ==="
    echo "NFS IP: ${HOST_IP} -> ${NFS_HOSTNAME}"
    echo "KDC Server IP: ${KDC_SERVER_IP} -> ${KDC_HOSTNAME}"
    if [[ "${K8S_SERVER_IP}" != "${HOST_IP}" ]]; then
        echo "K8S Server IP: ${K8S_SERVER_IP} -> ${K8S_HOSTNAME}"
    fi
else
    echo "=== Installing NFS Server with Kerberos on Ubuntu 24.04 (Single-Node) ==="
    echo "Host IP: ${HOST_IP}"
    echo "NFS/KDC Hostname: ${NFS_HOSTNAME} / ${KDC_HOSTNAME}"
fi

# Update system
apt-get update && apt-get upgrade -y

# Install NFS and Kerberos packages
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nfs-kernel-server \
    nfs-common \
    krb5-user \
    keyutils \
    curl \
    wget

# Create NFS export directories
echo "Creating NFS export directories..."
mkdir -p /exports
mkdir -p /exports/home
mkdir -p /exports/shared

# Create user directories with proper ownership
echo "Creating user directories..."
for uid in 10002 10003 10004; do
    gid=$((uid - 5000))  # 5002, 5003, 5004
    user="user${uid}"

    # Create group if it doesn't exist
    groupadd -g "${gid}" group"${gid}" || true

    # Create user if it doesn't exist
    useradd -u "${uid}" -g "${gid}" -m -d /exports/home/${user} -s /bin/bash "${user}" || true

    # Create home directory in exports
    mkdir -p /exports/home/"${user}"
    chown "${uid}":"${gid}" /exports/home/"${user}"
    chmod 700 /exports/home/"${user}"

    # Create a welcome file
    echo "Welcome ${user} to Kerberos NFS!" > /exports/home/"${user}"/welcome.txt
    chown "${uid}":"${gid}" /exports/home/"${user}"/welcome.txt
done

# Create shared directory
chmod 777 /exports/shared
echo "Shared NFS directory with Kerberos authentication" > /exports/shared/readme.txt

# Configure NFS exports with Kerberos
cat > /etc/exports <<EOF
# NFSv4 root
/exports *(rw,sync,no_subtree_check,no_root_squash,fsid=0,sec=sys:krb5:krb5i:krb5p)

# Shared directory - accessible by all authenticated users
/exports/shared *(rw,sync,no_subtree_check,no_root_squash,sec=sys:krb5:krb5i:krb5p)

# User home directories - each user can only access their own
# /exports/home/user10002 *(rw,sync,no_subtree_check,no_root_squash,sec=krb5:krb5i:krb5p)
# /exports/home/user10003 *(rw,sync,no_subtree_check,no_root_squash,sec=krb5:krb5i:krb5p)
# /exports/home/user10004 *(rw,sync,no_subtree_check,no_root_squash,sec=krb5:krb5i:krb5p)

# with sec=sys
/exports/home/user10002 *(rw,sync,no_subtree_check,no_root_squash,sec=sys:krb5:krb5i:krb5p)
/exports/home/user10003 *(rw,sync,no_subtree_check,no_root_squash,sec=sys:krb5:krb5i:krb5p)
/exports/home/user10004 *(rw,sync,no_subtree_check,no_root_squash,sec=sys:krb5:krb5i:krb5p)
EOF

# Configure NFSv4 domain
cat > /etc/idmapd.conf <<EOF
[General]
Domain = ${DOMAIN}

[Mapping]
Nobody-User = nobody
Nobody-Group = nogroup

[Translation]
Method = nsswitch
EOF

# Configure NFS for Kerberos
cat >> /etc/default/nfs-kernel-server <<EOF

# Enable GSS security for NFSv4
NEED_SVCGSSD=yes
RPCNFSDARGS="-N 2 -N 3"
EOF

cat >> /etc/default/nfs-common <<EOF

# Enable GSS security
NEED_GSSD=yes
NEED_IDMAPD=yes
EOF

# Download Kerberos configuration from KDC
print_yellow "=== Downloading Kerberos configuration from KDC ==="
# Clean up any existing Kerberos files first
rm -f /etc/krb5.conf
rm -f /etc/krb5.keytab
rm -f /etc/keytabs/nfs.keytab

print_yellow "Downloading krb5.conf from http://${KDC_HOSTNAME}:8080/"
wget -O /etc/krb5.conf "http://${KDC_HOSTNAME}:8080/krb5.conf" || {
    print_red "ERROR: Failed to download krb5.conf from KDC"
    print_red "Make sure the KDC is running and accessible at ${KDC_HOSTNAME}:8080"
    exit 1
}

print_yellow "Downloading NFS keytab from KDC..."
mkdir -p /etc/keytabs
wget -O /etc/krb5.keytab "http://${KDC_HOSTNAME}:8080/keytabs/nfs.keytab" || {
    print_red "ERROR: Failed to download NFS keytab from KDC"
    exit 1
}
chmod 600 /etc/krb5.keytab
print_green "✓ Kerberos configuration downloaded successfully"

# Extract KDC server IP from hostname (format: kdc-IP.nip.io)
KDC_IP=$(echo "${KDC_HOSTNAME}" | sed 's/kdc-\([0-9.]*\)\.nip\.io/\1/')

# Configure firewall
if false; then
    print_yellow "=== Configuring UFW firewall ==="
    ufw --force enable

    # NFS specific ports
    ufw allow 2049/tcp   # NFS
    ufw allow 2049/udp   # NFS
    ufw allow 111/tcp    # RPC portmapper
    ufw allow 111/udp    # RPC portmapper
    ufw allow 20048/tcp  # mountd
    ufw allow 20048/udp  # mountd
    ufw allow 22/tcp     # SSH

    # Allow access from KDC server specifically (for keytab downloads)
    if [[ "${KDC_IP}" != "${KDC_HOSTNAME}" ]]; then
        echo "Allowing access from KDC server: ${KDC_IP}"
        ufw allow from "${KDC_IP}"
    else
        echo "WARNING: Could not extract IP from KDC hostname: ${KDC_HOSTNAME}"
    fi

    # Allow access from Kubernetes node if specified
    if [[ -n "${K8S_HOSTNAME}" ]]; then
        K8S_IP=$(echo "${K8S_HOSTNAME}" | sed 's/k8s-\([0-9.]*\)\.nip\.io/\1/')
        if [[ "${K8S_IP}" != "${K8S_HOSTNAME}" ]]; then
            echo "Allowing NFS access from K8s node: ${K8S_IP}"
            ufw allow from "${K8S_IP}" to any port 2049     # NFS
            ufw allow from "${K8S_IP}" to any port 111      # RPC portmapper
            ufw allow from "${K8S_IP}" to any port 20048    # mountd
        else
            echo "WARNING: Could not extract IP from K8s hostname: ${K8S_HOSTNAME}"
        fi
    fi

    # Fallback: Allow access from common private network ranges for any other K8s nodes
    echo "Allowing NFS access from common private network ranges"
    ufw allow from 10.0.0.0/8 to any port 2049       # NFS
    ufw allow from 10.0.0.0/8 to any port 111        # RPC portmapper
    ufw allow from 10.0.0.0/8 to any port 20048      # mountd
    ufw allow from 172.16.0.0/12 to any port 2049    # Docker/K8s networks - NFS
    ufw allow from 172.16.0.0/12 to any port 111     # Docker/K8s networks - RPC
    ufw allow from 172.16.0.0/12 to any port 20048   # Docker/K8s networks - mountd
    ufw allow from 192.168.0.0/16 to any port 2049   # Private networks - NFS
    ufw allow from 192.168.0.0/16 to any port 111    # Private networks - RPC
    ufw allow from 192.168.0.0/16 to any port 20048  # Private networks - mountd
fi

# Start and enable NFS services
print_yellow "=== Starting NFS services ==="

systemctl enable nfs-kernel-server
systemctl enable nfs-idmapd
systemctl enable rpc-gssd
systemctl enable rpc-svcgssd

systemctl start rpc-gssd
systemctl start rpc-svcgssd
systemctl start nfs-idmapd
systemctl start nfs-kernel-server

# Export the filesystems
exportfs -ra

print_green "=== NFS Server Installation Complete ==="
echo "NFS Server: ${NFS_HOSTNAME}"
echo ""
echo "Exports available:"
exportfs -v
