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

# users and groups
USERS=("user10002" "user10003" "user10004" "user10005" "user10006")
GROUPS=("group5002" "group5003" "group5004" "group5005" "group5006"
)
print_yellow "Starting Kubernetes cluster cleanup..."

# Reset Kubernetes cluster
print_yellow "Resetting Kubernetes cluster with kubeadm..."
sudo kubeadm reset -f --cleanup-tmp-dir

# Stop and disable kubelet
print_yellow "Stopping kubelet service..."
sudo systemctl stop kubelet || true

# Remove Kubernetes data (but leave containerd alone)
print_yellow "Cleaning up Kubernetes data..."
sudo rm -rf /var/lib/kubelet/
sudo rm -rf /var/lib/etcd/

# Remove Calico-related files
print_yellow "Removing Calico CNI configurations..."
sudo rm -f /etc/cni/net.d/10-calico.conflist
sudo rm -f /etc/cni/net.d/calico-kubeconfig
sudo rm -rf /var/log/calico/
sudo rm -f /usr/local/bin/calicoctl

# Remove Calico-related files
echo "Removing Calico CNI configurations..."
sudo rm -rf /var/log/calico/
sudo rm -f /usr/local/bin/calicoctl

# Clean up network interfaces created by CNI
for iface in cni0 flannel.1; do
    if ip link show "$iface" &>/dev/null; then
        sudo ip link set "$iface" down
        sudo ip link delete "$iface"
    fi
done

# Clean up Calico interfaces
for cali in $(ip link 2>/dev/null | grep cali | cut -f2 -d" " | cut -f1 -d@ || true); do
    sudo ip link delete "${cali}" 2>/dev/null || true
done

# Clean up Kubernetes configurations
print_yellow "Cleaning up Kubernetes configurations..."
sudo rm -rf /etc/kubernetes/
sudo rm -rf ~/.kube/
sudo rm -f kubeadm-config.yaml
sudo rm -f /tmp/kubeadm-config.yaml

# clear local users created for testing
print_yellow "Removing local test users..."
for user in "${USERS[@]}"; do
    sudo deluser --remove-home "${user}" || true
done

# clear local groups created for testing
print_yellow "Removing local test groups..."
for group in "${GROUPS[@]}"; do
    sudo delgroup "${group}" || true
done

# Clean up OCI hooks and related files
print_yellow "Cleaning up OCI hooks and state files..."
sudo rm -rf /opt/nri-hooks/
sudo rm -f /var/log/nri-kerberos.log
sudo rm -f /opt/nri/plugins/10-kerberos

# Clean up Kerberos credential caches
print_yellow "Cleaning up Kerberos credential caches..."
sudo rm -f /tmp/krb5cc_*
print_yellow "Note: This removes ALL credential caches including system ones - they will be recreated on next deploy"

# Clean up logs
print_yellow "Cleaning up Kubernetes logs..."
sudo journalctl --rotate --vacuum-time=1s --unit=kubelet.service

print_green "Kubernetes Cluster Cleanup Complete"
