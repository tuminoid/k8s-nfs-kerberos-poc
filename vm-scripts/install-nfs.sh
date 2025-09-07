#!/usr/bin/env bash

# Ubuntu 24.04 NFS Server with Kerberos Installation Script
# Run this on a dedicated VM for the NFS server

set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Auto-detect IP address from ens3 interface
HOST_IP=$(ip addr show ens3 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Could not detect IP address from ens3 interface"
    exit 1
fi

# Configuration - Update these as needed
REALM="EXAMPLE.COM"
DOMAIN="example.com"
KDC_SERVER="kdc.${DOMAIN}"
NFS_SERVER="nfs.${DOMAIN}"

echo "=== Installing NFS Server with Kerberos on Ubuntu 24.04 ==="
echo "Detected Host IP: ${HOST_IP}"

# Set up /etc/hosts entry for NFS
echo "Setting up /etc/hosts entry for NFS..."
sed -i "/${NFS_SERVER}/d" /etc/hosts
echo "${HOST_IP} ${NFS_SERVER}" >> /etc/hosts
echo "✓ NFS hostname configured in /etc/hosts"

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
    groupadd -g ${gid} group${uid} || true

    # Create user if it doesn't exist
    useradd -u ${uid} -g ${gid} -m -d /exports/home/${user} -s /bin/bash ${user} || true

    # Create home directory in exports
    mkdir -p /exports/home/${user}
    chown ${uid}:${gid} /exports/home/${user}
    chmod 700 /exports/home/${user}

    # Create a welcome file
    echo "Welcome ${user} to Kerberos NFS!" > /exports/home/${user}/welcome.txt
    chown ${uid}:${gid} /exports/home/${user}/welcome.txt
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

# Configure firewall
echo "=== Configuring UFW firewall ==="
ufw --force enable
ufw allow 2049/tcp   # NFS
ufw allow 2049/udp   # NFS
ufw allow 111/tcp    # RPC portmapper
ufw allow 111/udp    # RPC portmapper
ufw allow 20048/tcp  # mountd
ufw allow 20048/udp  # mountd
ufw allow 22/tcp     # SSH
ufw allow from 10.0.0.0/8      # Allow internal networks
ufw allow from 172.16.0.0/12   # Allow Docker networks
ufw allow from 192.168.0.0/16  # Allow private networks

# Start and enable NFS services
echo "=== Starting NFS services ==="

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

echo "=== NFS Server Installation Complete ==="
echo "NFS Server: ${NFS_SERVER}"
echo ""
echo "Exports available:"
exportfs -v
