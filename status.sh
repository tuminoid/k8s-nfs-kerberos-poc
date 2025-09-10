#!/usr/bin/env bash
# Quick status check for the entire NFS Kerberos setup

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Color print functions
print_red() { echo -e "${RED}$*${NC}"; }
print_green() { echo -e "${GREEN}$*${NC}"; }
print_yellow() { echo -e "${YELLOW}$*${NC}"; }

# Configuration - detect from configmap or use defaults
if kubectl get configmap service-hostnames &> /dev/null; then
    KDC_SERVER=$(kubectl get configmap service-hostnames -o jsonpath='{.data.KDC_HOSTNAME}' 2>/dev/null || echo "kdc.example.com")
    NFS_SERVER=$(kubectl get configmap service-hostnames -o jsonpath='{.data.NFS_HOSTNAME}' 2>/dev/null || echo "nfs.example.com")
else
    # Fallback to auto-detection for single-node setup
    HOST_IP=$(ip addr show ens3 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 2>/dev/null || echo "")
    KDC_SERVER="kdc-${HOST_IP}.nip.io"
    NFS_SERVER="nfs-${HOST_IP}.nip.io"
fi

print_green "=== NFS Kerberos POC Status ==="
echo

# Check if cluster is accessible
if kubectl cluster-info > /dev/null 2>&1; then
    print_green "✓ Kubernetes cluster accessible"

    # Check PVs
    print_yellow "Persistent Volumes:"
    kubectl get pv 2>/dev/null | grep nfs-pv || echo "No NFS PVs found"

    # Check PVCs
    print_yellow "Persistent Volume Claims:"
    kubectl get pvc 2>/dev/null | grep nfs- || echo "No NFS PVCs found"

    # Check pods
    print_yellow "Client Pods:"
    kubectl get pods 2>/dev/null | grep client- || echo "No client pods found"

    # Quick test if any pods are running
    if kubectl get pod client-user10002 > /dev/null 2>&1; then
        POD_STATUS=$(kubectl get pod client-user10002 -o jsonpath='{.status.phase}' 2>/dev/null)
        print_yellow "Quick NFS Test:"
        echo "Testing user10002 home directory access:"
        if [[ "${POD_STATUS}" = "Running" ]]; then
            kubectl exec client-user10002 -- ls -la /home/ 2>/dev/null && print_green "✓ NFS mount accessible" || print_red "✗ Failed to access NFS"
        else
            echo "Pod not yet running (Status: ${POD_STATUS})"

            # Show detailed pod information for troubleshooting
            print_yellow "Pod Details for Troubleshooting:"
            for pod in client-user10002 client-user10003 client-user10004; do
                if kubectl get pod "${pod}" > /dev/null 2>&1; then
                    POD_PHASE=$(kubectl get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null)
                    print_yellow "--- Pod: ${pod} (Status: ${POD_PHASE}) ---"

                    if [[ "${POD_PHASE}" != "Running" ]]; then
                        echo "Events and conditions:"
                        kubectl describe pod "${pod}" | grep -A 20 "Events:" || echo "No events found"

                        # Check for specific error patterns
                        DESCRIBE_OUTPUT=$(kubectl describe pod "${pod}" 2>/dev/null)
                        if echo "${DESCRIBE_OUTPUT}" | grep "mount.*failed\|nfs.*error\|permission.*denied" &>/dev/null; then
                            print_red "⚠ NFS mount issues detected"
                        fi
                        if echo "${DESCRIBE_OUTPUT}" | grep "image.*pull\|ErrImagePull" &>/dev/null; then
                            print_red "⚠ Image pull issues detected"
                        fi
                        if echo "${DESCRIBE_OUTPUT}" | grep "unbound.*PersistentVolumeClaim" &>/dev/null; then
                            print_red "⚠ PVC binding issues detected"
                        fi
                    fi
                fi
            done
        fi
    fi
else
    print_red "✗ Kubernetes cluster not accessible"
fi

# Check VM servers
print_yellow "Checking VM servers..."
echo "NFS Server: ${NFS_SERVER}"
if command -v nc > /dev/null 2>&1; then
    if nc -z "${NFS_SERVER}" 2049 2>/dev/null; then
        print_green "✓ NFS server port 2049 accessible"
    else
        print_red "✗ NFS server port 2049 not accessible"
    fi
else
    echo "netcat not available - cannot test NFS port"
fi

echo "KDC Server: ${KDC_SERVER}"
if command -v curl > /dev/null 2>&1; then
    if curl -s --connect-timeout 2 "http://${KDC_SERVER}:8080/" > /dev/null 2>&1; then
        print_green "✓ KDC HTTP server accessible"
    else
        print_red "✗ KDC server not accessible on port 8080"
    fi
else
    echo "curl not available - cannot test KDC server"
fi

# Check if setup has been run (prerequisite services configured)
print_yellow "Setup Validation:"
echo

SETUP_COMPLETE=true

# Check if KCM service is configured
if systemctl list-unit-files | grep &>/dev/null "kcm.service"; then
    if systemctl is-enabled --quiet kcm 2>/dev/null; then
        print_green "✓ KCM service configured and enabled"
    else
        print_yellow "⚠ KCM service exists but not enabled"
        echo "  Fix: sudo systemctl enable kcm"
        SETUP_COMPLETE=false
    fi
else
    print_red "✗ KCM service not configured"
    echo "  Fix: Run vm-scripts/setup-k8s-node.sh first"
    SETUP_COMPLETE=false
fi

# Check if system credentials service is configured
if systemctl list-unit-files | grep &>/dev/null "kerberos-system-creds.service"; then
    if systemctl is-enabled --quiet kerberos-system-creds 2>/dev/null; then
        print_green "✓ System credentials service configured"
    else
        print_yellow "⚠ System credentials service exists but not enabled"
        SETUP_COMPLETE=false
    fi
else
    print_red "✗ System credentials service not configured"
    echo "  Fix: Run vm-scripts/setup-k8s-node.sh first"
    SETUP_COMPLETE=false
fi

# Check kernel modules configuration
if [[ -f /etc/modules-load.d/nfs-kerberos.conf ]]; then
    print_green "✓ NFS Kerberos kernel modules configured for boot"
else
    print_red "✗ Kernel modules not configured for persistent loading"
    echo "  Fix: Run vm-scripts/setup-k8s-node.sh first"
    SETUP_COMPLETE=false
fi

if [[ "${SETUP_COMPLETE}" == "false" ]]; then
    echo
    print_red "⚠ SETUP INCOMPLETE: Run vm-scripts/setup-k8s-node.sh before deploy-k8s.sh"
    echo
fi

# Check critical daemons for NFS Kerberos
print_yellow "Critical Daemon Status:"
echo

# Check rpcbind
if systemctl is-active --quiet rpcbind; then
    print_green "✓ rpcbind service running"
else
    print_red "✗ rpcbind service not running"
    echo "  Fix: sudo systemctl start rpcbind"
fi

# Check rpc-gssd (critical for Kerberos NFS)
if systemctl is-active --quiet rpc-gssd; then
    print_green "✓ rpc-gssd service running"
else
    print_red "✗ rpc-gssd service not running (CRITICAL)"
    echo "  Fix: sudo systemctl start rpc-gssd"
fi

# Check nfs-idmapd (needed for user mapping)
if systemctl is-active --quiet nfs-idmapd; then
    print_green "✓ nfs-idmapd service running"
else
    print_red "✗ nfs-idmapd service not running"
    echo "  Fix: sudo systemctl start nfs-idmapd"
fi

# Check KCM daemon (for credential sharing)
if ls -la /var/run/ | grep &>/dev/null kcm; then
    print_green "✓ KCM socket available"
else
    print_red "✗ KCM socket not found"
    echo "  Fix: /usr/sbin/kcm --detach"
fi

# Check kernel modules
print_yellow "\nKernel Modules:"
if lsmod | grep &>/dev/null auth_rpcgss; then
    print_green "✓ auth_rpcgss module loaded"
else
    print_red "✗ auth_rpcgss module not loaded"
    echo "  Fix: sudo modprobe auth_rpcgss"
fi

if lsmod | grep &>/dev/null rpcsec_gss_krb5; then
    print_green "✓ rpcsec_gss_krb5 module loaded"
else
    print_red "✗ rpcsec_gss_krb5 module not loaded"
    echo "  Fix: sudo modprobe rpcsec_gss_krb5"
fi

# Check RPC pipefs mount
if mount | grep &>/dev/null rpc_pipefs; then
    print_green "✓ RPC pipefs mounted"
else
    print_red "✗ RPC pipefs not mounted"
    echo "  Fix: sudo mount -t rpc_pipefs sunrpc /var/lib/nfs/rpc_pipefs"
fi

# Check NFSv4 domain configuration
if grep &>/dev/null "^Domain = example.com" /etc/idmapd.conf 2>/dev/null; then
    print_green "✓ NFSv4 domain configured (example.com)"
else
    print_red "✗ NFSv4 domain not configured"
    echo "  Fix: echo 'Domain = example.com' | sudo tee -a /etc/idmapd.conf"
fi

# Check system credentials for kubelet
if sudo klist -c FILE:/tmp/krb5cc_0 &>/dev/null; then
    print_green "✓ System Kerberos credentials available"
else
    print_red "✗ No system Kerberos credentials"
    echo "  Fix: sudo kinit -kt /etc/keytabs/user10002.keytab user10002@EXAMPLE.COM"
fi

echo

echo "Logs from krb5-sidecar:"
kubectl logs client-user10002-kcm -c krb5-sidecar
echo

echo "Logs from nfs-client:"
kubectl logs client-user10002-kcm -c nfs-client
echo
