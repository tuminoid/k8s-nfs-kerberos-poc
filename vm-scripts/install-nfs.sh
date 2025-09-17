#!/usr/bin/env bash

# Run this on a dedicated VM for the NFS server
# Usage: ./install-nfs.sh <kdc_hostname> <k8s_hostname>

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

# Parameters - KDC and K8S IPs are required for multi-server setup
if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
    print_red "ERROR: KDC and K8S server IPs are required"
    echo "Usage: $0 <kdc_server_ip> <k8s_server_ip>"
    exit 1
fi

KDC_SERVER_IP="$1"
K8S_SERVER_IP="$2"

# Expand IPs to full nip.io hostnames
KDC_HOSTNAME="kdc-${KDC_SERVER_IP}.nip.io"
NFS_HOSTNAME="nfs-${HOST_IP}.nip.io"
K8S_HOSTNAME="k8s-${K8S_SERVER_IP}.nip.io"

# Configuration using nip.io
REALM="EXAMPLE.COM"
DOMAIN="example.com"

# Users to provision
USERS=("user10002" "user10003" "user10004" "user10005" "user10006")

echo "=== Installing NFS Server with Kerberos on Ubuntu 24.04 (Multi-Server) ==="
echo "NFS IP: ${HOST_IP} -> ${NFS_HOSTNAME}"
echo "KDC Server IP: ${KDC_SERVER_IP} -> ${KDC_HOSTNAME}"
echo "K8S Server IP: ${K8S_SERVER_IP} -> ${K8S_HOSTNAME}"

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
for user in "${USERS[@]}"; do
    uid=${user#user}  # Extract UID from username (e.g., user10002 -> 10002)
    gid=$((uid - 5000))  # 5002, 5003, 5004, 5005, 5006

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
/exports *(rw,sync,no_subtree_check,fsid=0,sec=sys:krb5:krb5i:krb5p)

# Shared directory - accessible by all authenticated users
/exports/shared *(rw,sync,no_subtree_check,sec=sys:krb5:krb5i:krb5p)
EOF

# Add user home directory exports dynamically
for user in "${USERS[@]}"; do
    cat >> /etc/exports <<EOF
# User home directory for ${user}
/exports/home/${user} *(rw,sync,no_subtree_check,sec=sys:krb5:krb5i:krb5p)
EOF
done

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
