#!/usr/bin/env bash

set -eu

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

USERS=("user10002" "user10003" "user10004")
GROUPS=("group10002" "group10003" "group10004")

echo -e "${YELLOW}Starting NFS and Kerberos cleanup...${NC}"

# Stop and clean up local NFS/Kerberos processes
echo -e "${YELLOW}Stopping local Kerberos and NFS processes...${NC}"
sudo pkill -f rpc.gssd || true
sudo pkill -f kcm || true
sudo umount /var/lib/nfs/rpc_pipefs 2>/dev/null || true

# Stop NFS and Kerberos services
echo -e "${YELLOW}Stopping NFS and Kerberos services...${NC}"
sudo systemctl stop nfs-kernel-server || true
sudo systemctl stop rpc-gssd || true
sudo systemctl stop krb5-kdc || true
sudo systemctl stop krb5-admin-server || true
sudo systemctl stop nginx || true

# Clean up Docker images related to our project
echo -e "${YELLOW}Cleaning up Docker images...${NC}"
docker rmi nfs-kerberos-client:latest || true
docker rmi krb5-sidecar:latest || true
docker system prune -f

# Clean up containerd images
echo -e "${YELLOW}Cleaning up containerd images...${NC}"
sudo ctr -n k8s.io images rm docker.io/library/nfs-kerberos-client:latest || true
sudo ctr -n k8s.io images rm docker.io/library/krb5-sidecar:latest || true

# Clean up NFS exports and data
echo -e "${YELLOW}Cleaning up NFS exports and user data...${NC}"
sudo exportfs -ua || true
sudo rm -rf /exports/home/*

# Clean up Kerberos database and configuration
echo -e "${YELLOW}Cleaning up Kerberos database...${NC}"
sudo rm -rf /var/lib/krb5kdc/
sudo rm -f /etc/krb5.keytab
sudo rm -rf /etc/keytabs/*

# Clean up local user accounts
echo -e "${YELLOW}Removing test user accounts...${NC}"
for user in "${USERS[@]}"; do
    sudo userdel -r "${user}" 2>/dev/null || true
done
for group in "${GROUPS[@]}"; do
    sudo groupdel "${group}" 2>/dev/null || true
done

# Clean up HTTP server keytab distribution
echo -e "${YELLOW}Cleaning up HTTP keytab server...${NC}"
sudo rm -rf /var/www/html/keytabs/* || true

# Clean up hostname entries from /etc/hosts
echo -e "${YELLOW}Cleaning up hostname entries from /etc/hosts...${NC}"
sudo sed -i '/kdc\.example\.com/d' /etc/hosts || true
sudo sed -i '/nfs\.example\.com/d' /etc/hosts || true

echo -e "${GREEN}"
echo "=================================================================="
echo "NFS and Kerberos Cleanup Complete"
echo "=================================================================="
echo "${NC}"
