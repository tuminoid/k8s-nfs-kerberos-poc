#!/usr/bin/env bash

set -eu

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting Kubernetes cluster cleanup...${NC}"

# Reset Kubernetes cluster
echo -e "${YELLOW}Resetting Kubernetes cluster with kubeadm...${NC}"
sudo kubeadm reset -f --cleanup-tmp-dir

# Stop and disable kubelet
echo -e "${YELLOW}Stopping kubelet service...${NC}"
sudo systemctl stop kubelet || true

# Remove Kubernetes data (but leave containerd alone)
echo -e "${YELLOW}Cleaning up Kubernetes data...${NC}"
sudo rm -rf /var/lib/kubelet/
sudo rm -rf /var/lib/etcd/

# Remove Calico-related files
echo -e "${YELLOW}Removing Calico CNI configurations...${NC}"
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
echo -e "${YELLOW}Cleaning up Kubernetes configurations...${NC}"
sudo rm -rf /etc/kubernetes/
sudo rm -rf ~/.kube/
sudo rm -f kubeadm-config.yaml
sudo rm -f /tmp/kubeadm-config.yaml

# Clean up logs
echo -e "${YELLOW}Cleaning up Kubernetes logs...${NC}"
sudo journalctl --rotate --vacuum-time=1s --unit=kubelet.service

echo -e "${GREEN}"
echo "=================================================================="
echo "Kubernetes Cluster Cleanup Complete"
echo "${NC}"
