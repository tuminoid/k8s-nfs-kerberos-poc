#!/usr/bin/env bash

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Color print functions
print_red() { echo -e "${RED}$*${NC}"; }
print_green() { echo -e "${GREEN}$*${NC}"; }
print_yellow() { echo -e "${YELLOW}$*${NC}"; }

USERS=("user10002" "user10003" "user10004")
GROUPS=("group10002" "group10003" "group10004")

print_yellow "Starting NFS and Kerberos cleanup..."

# Stop and clean up local NFS/Kerberos processes
print_yellow "Stopping local Kerberos and NFS processes..."
sudo pkill -f rpc.gssd || true
sudo pkill -f kcm || true
sudo umount /var/lib/nfs/rpc_pipefs 2>/dev/null || true

# Stop NFS and Kerberos services
print_yellow "Stopping NFS and Kerberos services..."
sudo systemctl stop nfs-kernel-server || true
sudo systemctl stop rpc-gssd || true
sudo systemctl stop krb5-kdc || true
sudo systemctl stop krb5-admin-server || true
sudo systemctl stop nginx || true

# Clean up Docker images related to our project
print_yellow "Cleaning up Docker images..."
docker rmi nfs-kerberos-client:latest || true
docker rmi krb5-sidecar:latest || true
docker system prune -f

# Clean up containerd images
print_yellow "Cleaning up containerd images..."
sudo ctr -n k8s.io images rm docker.io/library/nfs-kerberos-client:latest || true
sudo ctr -n k8s.io images rm docker.io/library/krb5-sidecar:latest || true

# Clean up NFS exports and data
print_yellow "Cleaning up NFS exports and user data..."
sudo exportfs -ua || true
sudo rm -rf /exports/home/*

# Clean up Kerberos database and configuration
print_yellow "Cleaning up Kerberos database and credentials..."
# Stop Kerberos services first to avoid conflicts
sudo systemctl stop krb5-kdc || true
sudo systemctl stop krb5-admin-server || true

# Clean up database and configuration files
sudo rm -rf /var/lib/krb5kdc/
sudo rm -f /etc/krb5.keytab
sudo rm -rf /etc/keytabs/*
sudo rm -f /etc/krb5.conf

# Clean up Kerberos ticket caches for all users
print_yellow "Cleaning up Kerberos ticket caches..."
sudo kdestroy -A 2>/dev/null || true
for user in "${USERS[@]}"; do
    sudo -u "${user}" kdestroy -A 2>/dev/null || true
done
# Clean up system-wide ticket caches
sudo rm -f /tmp/krb5cc_* || true
sudo rm -f /var/tmp/krb5cc_* || true

# Clean up local user accounts
print_yellow "Removing test user accounts..."
for user in "${USERS[@]}"; do
    sudo userdel -r "${user}" 2>/dev/null || true
done
for group in "${GROUPS[@]}"; do
    sudo groupdel "${group}" 2>/dev/null || true
done

# Clean up HTTP server keytab distribution
print_yellow "Cleaning up HTTP keytab server..."
sudo rm -rf /var/www/html/keytabs/* || true

print_green "NFS and Kerberos Cleanup Complete"
