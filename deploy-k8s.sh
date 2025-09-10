#!/usr/bin/env bash
# Kubernetes NFS Kerberos Client Deployment Script
# Run this on the Kubernetes node
# Usage: ./deploy-k8s.sh [kdc_server_ip] [nfs_server_ip] [k8s_version]

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Color print functions
print_red() { echo -e "${RED}$*${NC}"; }
print_green() { echo -e "${GREEN}$*${NC}"; }
print_yellow() { echo -e "${YELLOW}$*${NC}"; }

# Auto-detect IP address from ens3 interface
HOST_IP=$(ip addr show ens3 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
if [[ -z "${HOST_IP}" ]]; then
    print_red "ERROR: Could not detect IP address from ens3 interface"
    exit 1
fi

# Parameters - if KDC/NFS IPs are provided, use them; otherwise assume single-node setup
KDC_SERVER_IP="${1:-${HOST_IP}}"
NFS_SERVER_IP="${2:-${HOST_IP}}"
K8S_VERSION="${3:-1.32}"

# Expand IPs to full nip.io hostnames
KDC_HOSTNAME="kdc-${KDC_SERVER_IP}.nip.io"
NFS_HOSTNAME="nfs-${NFS_SERVER_IP}.nip.io"
K8S_HOSTNAME="k8s-${HOST_IP}.nip.io"

# Configuration using nip.io
REALM="EXAMPLE.COM"

if [[ "${KDC_SERVER_IP}" != "${HOST_IP}" ]] || [[ "${NFS_SERVER_IP}" != "${HOST_IP}" ]]; then
    print_yellow "=== Multi-Server Deployment ==="
    print_yellow "K8S: ${HOST_IP} -> ${K8S_HOSTNAME}"
    print_yellow "KDC: ${KDC_SERVER_IP} -> ${KDC_HOSTNAME}"
    print_yellow "NFS: ${NFS_SERVER_IP} -> ${NFS_HOSTNAME}"
else
    print_yellow "=== Single-Node Deployment ==="
    print_yellow "Host: ${HOST_IP} -> ${KDC_HOSTNAME} / ${NFS_HOSTNAME}"
fi

# we can provision up to 3 users
USERS=("user10002" "user10003" "user10004")

# Check if Kubernetes tools are installed
if ! command -v kubectl &> /dev/null || ! command -v kubeadm &> /dev/null; then
    print_red "ERROR: Kubernetes prerequisites not installed!"
    print_yellow "Please run ./vm-scripts/setup-k8s-node.sh first"
    exit 1
fi

print_green "✓ Kubernetes prerequisites detected"

# Build custom NFS Kerberos client Docker image
print_yellow "Build NFS Kerberos client Docker image..."
docker build -t nfs-kerberos-client:latest containers/nfs-client/
print_green "✓ NFS Kerberos client image built"

# Build KCM sidecar Docker image
print_yellow "Build KCM sidecar Docker image..."
docker build -t krb5-sidecar:latest containers/krb5-sidecar/
print_green "✓ KCM sidecar image built"

# Import images to containerd for Kubernetes
docker save nfs-kerberos-client:latest | sudo ctr -n k8s.io images import -
docker save krb5-sidecar:latest | sudo ctr -n k8s.io images import -
print_green "✓ Images imported to containerd"

# Check if cluster is already running
if kubectl cluster-info &> /dev/null; then
    print_green "✓ Kubernetes cluster already running"
else
    print_yellow "Kubernetes cluster not accessible, checking kubelet..."

    # Check if kubelet is running
    if ! sudo systemctl is-active --quiet kubelet; then
        print_yellow "Kubelet not running, starting kubelet..."
        sudo systemctl start kubelet
        sleep 5
    fi

    # Try cluster-info again after starting kubelet
    if kubectl cluster-info &> /dev/null; then
        print_green "✓ Kubernetes cluster is now accessible"
    else
        print_yellow "Cluster not accessible, initializing fresh cluster..."

        # Reset any existing cluster state
        sudo kubeadm reset --force &> /dev/null || true
        sudo systemctl stop kubelet &> /dev/null || true

        print_yellow "Initializing Kubernetes cluster..."

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
        kubectl wait --for=condition=ready node --all --timeout=300s &> /dev/null

        # Handle certificate approval for kubelet serving certificates
        sleep 10
        kubectl get csr | grep Pending | grep kubelet-serving | awk '{print $1}' | xargs -I {} kubectl certificate approve {} &> /dev/null || true

        print_green "✓ Kubernetes cluster initialized"

        # Verify cluster is working properly
        if ! kubectl cluster-info &> /dev/null; then
            print_red "ERROR: Cluster initialization failed - cluster-info not accessible"
            exit 1
        fi

        if ! kubectl get nodes &> /dev/null; then
            print_red "ERROR: Cluster initialization failed - cannot get nodes"
            exit 1
        fi

        print_green "✓ Cluster verification passed"
    fi
fi

# Create configmap with hostnames for pods to use
kubectl create configmap service-hostnames \
    --from-literal=KDC_HOSTNAME="${KDC_HOSTNAME}" \
    --from-literal=NFS_HOSTNAME="${NFS_HOSTNAME}" \
    --from-literal=KERBEROS_REALM="${REALM}" \
    --dry-run=client -o yaml | kubectl apply -f -
print_green "✓ ConfigMap with service hostnames created"

# Ensure keytabs are fresh and synchronized
print_yellow "Refreshing keytabs to ensure synchronization..."

if [[ "${KDC_HOSTNAME}" = "kdc-${HOST_IP}.nip.io" ]]; then
    # Single-node setup: run commands locally
    sudo kadmin.local -q "ktadd -k /etc/keytabs/nfs.keytab nfs/${NFS_HOSTNAME}@${REALM} nfs/${NFS_SERVER_IP}@${REALM}"
    sudo cp /etc/keytabs/nfs.keytab /var/www/html/keytabs/nfs.keytab
    sudo cp /etc/keytabs/nfs.keytab /etc/krb5.keytab
    sudo chmod 600 /etc/krb5.keytab
else
    # Multi-node setup: download fresh keytab from KDC
    wget -O /tmp/fresh-nfs.keytab "http://${KDC_HOSTNAME}:8080/keytabs/nfs.keytab" || {
        print_red "ERROR: Failed to download fresh NFS keytab from KDC"
        print_yellow "Make sure the KDC is running and accessible at ${KDC_HOSTNAME}:8080"
        exit 1
    }

    # Verify the keytab contains the right principal
    if ! klist -k /tmp/fresh-nfs.keytab | grep -q "nfs/${NFS_HOSTNAME}@${REALM}"; then
        print_red "ERROR: Downloaded keytab does not contain nfs/${NFS_HOSTNAME}@${REALM}"
        print_yellow "Available principals in keytab:"
        klist -k /tmp/fresh-nfs.keytab
        exit 1
    fi

    sudo cp /tmp/fresh-nfs.keytab /etc/krb5.keytab
    sudo chmod 600 /etc/krb5.keytab
    rm -f /tmp/fresh-nfs.keytab
fi

print_green "✓ Fresh keytab installed"

# Authenticate host with NFS service principal for mounting (only needed in single-node setup)
if [[ "${KDC_HOSTNAME}" = "kdc-${HOST_IP}.nip.io" ]]; then
    # Single-node setup: host needs NFS service principal for local testing
    sudo kinit -kt /etc/krb5.keytab "nfs/${NFS_HOSTNAME}@${REALM}"
    print_green "✓ Host authenticated with NFS service principal"
else
    # Multi-node setup: K8s node doesn't authenticate as NFS service, only pods do
    print_yellow "Skipping host NFS authentication (multi-node setup - pods will authenticate)"
fi

# Initialize user credentials (get initial tickets)
# THIS IS SUPPOSED TO BE MOVED TO NRI PLUGINS
LOCAL_USERS=true
if [[ "${LOCAL_USERS}" = true ]]; then
    for user in "${USERS[@]}"; do
        sudo groupadd -g "$((${user#user} - 5000))" "group$((${user#user} - 5000))" 2>/dev/null || true
        sudo useradd -m -u "${user#user}" -g "group$((${user#user} - 5000))" "${user}" || true
        # Use the keytab to get initial credentials for each user
        sudo -u "${user}" kinit -k -t "/etc/keytabs/${user}.keytab" "${user}@${REALM}" || print_yellow "Warning: Failed to get initial credentials for ${user}"
        # Set long renewal time for deployment use
        sudo -u "${user}" kinit -R "${user}@${REALM}" 2>/dev/null || true
    done
    print_green "✓ Initial user credentials configured"
else
    # install NRI hookinjector
    # https://github.com/containerd/nri/tree/main/plugins/hook-injector
    print_yellow "Installing NRI hookinjector plugin..."
    NRI_HOOKINJECTOR_RELEASE_TAG=v0.10.0
    kubectl apply -k "github.com/containerd/nri/contrib/kustomize/hook-injector?ref=${NRI_HOOKINJECTOR_RELEASE_TAG}"

    # install plugin to handle keytabs etc
    # tbd
fi

# Initialize system credentials for immediate use (service should be set up by setup script)
print_yellow "Initializing system credentials for NFS operations..."
export KRB5CCNAME=FILE:/tmp/krb5cc_0
sudo -E kinit -k -t /etc/krb5.keytab "nfs/${NFS_HOSTNAME}@${REALM}" 2>/dev/null || true

# Start the system credentials service if keytab is available
sudo systemctl start kerberos-system-creds 2>/dev/null || true

print_green "✓ System credentials initialized"

# Ensure required daemons are running (they sometimes stop after cluster operations)
print_yellow "Restarting critical daemons to ensure fresh state..."

# Restart daemons to ensure they're running with fresh configuration
# (These should already be enabled by setup-k8s-node.sh)
sudo systemctl restart rpcbind rpc-gssd kcm || true
sudo systemctl start rpc-gssd || true

print_green "✓ Critical daemons restarted"

# Deploy Kubernetes manifests
kubectl apply -f k8s-manifests/storageclass.yaml
print_green "✓ Storage class deployed"

# Deploy PVs dynamically with correct NFS hostname
for user in "${USERS[@]}"; do
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-pv-${user}
spec:
  capacity:
    storage: 1Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-krb5
  mountOptions:
  - nfsvers=4.1
  - sec=krb5
  - proto=tcp
  nfs:
    path: /home/${user}
    server: ${NFS_HOSTNAME}
EOF
done
print_green "✓ Persistent volumes deployed"

# Deploy PVCs
for user in "${USERS[@]}"; do
    kubectl apply -f "k8s-manifests/pvc-${user}.yaml"
done
print_green "✓ Persistent volume claims deployed"

# Deploy client pods with KCM sidecar (they now use configmap for hostnames)
for user in "${USERS[@]}"; do
    kubectl apply -f "k8s-manifests/client-${user}-kcm.yaml"
done
print_green "✓ KCM-based NFS client pods deployed"

print_green "✓ Deployment complete!"
