#!/usr/bin/env bash
# Kubernetes NFS Kerberos Client Deployment Script
# Run this on the same node as KDC/NFS server for simplified setup

set -eu

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
K8S_VERSION="${1:-1.32}"  # Kubernetes version

# Auto-detect IP address from ens3 interface
HOST_IP=$(ip addr show ens3 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
if [ -z "$HOST_IP" ]; then
    echo -e "${RED}ERROR: Could not detect IP address from ens3 interface${NC}"
    exit 1
fi

# Use hostnames (should be set up by install-kdc.sh and install-nfs.sh)
REALM="EXAMPLE.COM"
DOMAIN="example.com"
KDC_SERVER="kdc.${DOMAIN}"
NFS_SERVER="nfs.${DOMAIN}"

# we can provision up to 3 users
USERS=("user10002" "user10003" "user10004")

# Check if Kubernetes tools are installed
if ! command -v kubectl &> /dev/null || ! command -v kubeadm &> /dev/null; then
    echo -e "${RED}ERROR: Kubernetes prerequisites not installed!${NC}"
    echo -e "${YELLOW}Please run ./vm-scripts/setup-k8s-node.sh first${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Kubernetes prerequisites detected${NC}"

# Update hostAliases in pod manifests to match current IP
echo -e "${YELLOW}Updating pod manifests with current IP address (${HOST_IP})...${NC}"
for manifest in k8s-manifests/client-user*-kcm.yaml; do
    if [ -f "$manifest" ]; then
        # Update the IP address in hostAliases section
        sed -i "s/- ip: \"[0-9.]*\"/- ip: \"${HOST_IP}\"/" "${manifest}"
        echo "Updated ${manifest}"
    fi
done
echo -e "${GREEN}✓ Pod manifests updated with current IP${NC}"

# Build custom NFS Kerberos client Docker image
echo -e "${YELLOW}Building NFS Kerberos client Docker image...${NC}"
docker build -t nfs-kerberos-client:latest containers/nfs-client/
echo -e "${GREEN}✓ NFS Kerberos client image built${NC}"

# Build KCM sidecar Docker image
echo -e "${YELLOW}Building KCM sidecar Docker image...${NC}"
docker build -t krb5-sidecar:latest containers/krb5-sidecar/
echo -e "${GREEN}✓ KCM sidecar image built${NC}"

# Import images to containerd for Kubernetes
echo -e "${YELLOW}Importing images to containerd...${NC}"
docker save nfs-kerberos-client:latest | sudo ctr -n k8s.io images import -
docker save krb5-sidecar:latest | sudo ctr -n k8s.io images import -
echo -e "${GREEN}✓ Images imported to containerd${NC}"

# Check if cluster is already running
if kubectl cluster-info &> /dev/null; then
    echo -e "${GREEN}✓ Kubernetes cluster already running${NC}"
else
    echo -e "${YELLOW}Initializing Kubernetes cluster...${NC}"

    # Create kubeadm configuration in /tmp
    KUBEADM_CONFIG="/tmp/kubeadm-config-$(date +%s).yaml"
    cat <<EOF > "${KUBEADM_CONFIG}"
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  kubeletExtraArgs:
  - name: cert-dir
    value: "/var/lib/kubelet/pki"
  - name: node-ip
    value: "${HOST_IP}"
  taints:
  - effect: NoSchedule
    key: node-role.kubernetes.io/control-plane
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: 192.168.0.0/16
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
serverTLSBootstrap: true
rotateCertificates: true
logging:
  verbosity: 2
EOF

    # Initialize cluster
    sudo kubeadm init --config "${KUBEADM_CONFIG}"

    # Clean up config file
    rm -f "${KUBEADM_CONFIG}"

    # Set up kubeconfig for the current user
    mkdir -p "${HOME}"/.kube
    sudo cp -i /etc/kubernetes/admin.conf "${HOME}"/.kube/config
    sudo chown "$(id -u):$(id -g)" "${HOME}"/.kube/config

    # Allow scheduling on control plane (single node setup)
    kubectl taint nodes --all node-role.kubernetes.io/control-plane-

    # Install Calico CNI network plugin
    kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

    # Wait for node to be ready
    echo -e "${YELLOW}Waiting for node to be ready...${NC}"
    kubectl wait --for=condition=ready node --all --timeout=300s

    # Handle certificate approval for kubelet serving certificates
    sleep 10
    kubectl get csr | grep Pending | grep kubelet-serving | awk '{print $1}' | xargs -I {} kubectl certificate approve {} || true

    echo -e "${GREEN}✓ Kubernetes cluster initialized${NC}"
fi

# Authenticate host with NFS service principal for mounting
echo "Authenticating host for NFS service principal..."
sudo kinit -kt /etc/krb5.keytab "nfs/${NFS_SERVER}@${REALM}"
echo -e "${GREEN}✓ Host authenticated with NFS service principal${NC}"

# Initialize user credentials (get initial tickets)
echo "Initializing user credentials..."
for user in "${USERS[@]}"; do
    echo "Getting initial credentials for ${user}..."
    # Use the keytab to get initial credentials for each user
    sudo -u "${user}" kinit -k -t /etc/keytabs/${user}.keytab ${user}@${REALM} || echo "Warning: Failed to get initial credentials for ${user}"
    # Set long renewal time for deployment use
    sudo -u "${user}" kinit -R ${user}@${REALM} 2>/dev/null || true
done

echo "✓ Initial user credentials configured"

# Deploy Kubernetes manifests
echo -e "${YELLOW}Deploying NFS storage class and PVs...${NC}"

# Deploy storage class
kubectl apply -f k8s-manifests/storageclass.yaml
echo -e "${GREEN}✓ Storage class deployed${NC}"

# Deploy PVs
for user in "${USERS[@]}"; do
    kubectl apply -f k8s-manifests/pv-${user}.yaml
done
echo -e "${GREEN}✓ Persistent volumes deployed${NC}"

# Deploy PVCs
for user in "${USERS[@]}"; do
    kubectl apply -f k8s-manifests/pvc-${user}.yaml
done
echo -e "${GREEN}✓ Persistent volume claims deployed${NC}"

# Deploy client pods with KCM sidecar
for user in "${USERS[@]}"; do
    kubectl apply -f k8s-manifests/client-${user}-kcm.yaml
done
echo -e "${GREEN}✓ KCM-based NFS client pods deployed${NC}"

echo -e "${GREEN}"
echo "=================================================================="
echo "Deployment Complete"
echo "=================================================================="
echo "${NC}"
