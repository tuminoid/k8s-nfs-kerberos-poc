#!/usr/bin/env bash
# Quick status check for the entire NFS Kerberos setup

set -eu

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
KDC_SERVER="kdc.example.com"
NFS_SERVER="nfs.example.com"

echo -e "${GREEN}=== NFS Kerberos POC Status ===${NC}"
echo

# Check if cluster is accessible
if kubectl cluster-info > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Kubernetes cluster accessible${NC}"

    # Check PVs
    echo -e "\n${YELLOW}Persistent Volumes:${NC}"
    kubectl get pv 2>/dev/null | grep nfs-pv || echo "No NFS PVs found"

    # Check PVCs
    echo -e "\n${YELLOW}Persistent Volume Claims:${NC}"
    kubectl get pvc 2>/dev/null | grep nfs- || echo "No NFS PVCs found"

    # Check pods
    echo -e "\n${YELLOW}Client Pods:${NC}"
    kubectl get pods 2>/dev/null | grep client- || echo "No client pods found"

    # Quick test if any pods are running
    if kubectl get pod client-user10002 > /dev/null 2>&1; then
        POD_STATUS=$(kubectl get pod client-user10002 -o jsonpath='{.status.phase}' 2>/dev/null)
        echo -e "\n${YELLOW}Quick NFS Test:${NC}"
        echo "Testing user10002 home directory access:"
        if [ "$POD_STATUS" = "Running" ]; then
            kubectl exec client-user10002 -- ls -la /home/ 2>/dev/null && echo -e "${GREEN}✓ NFS mount accessible${NC}" || echo -e "${RED}✗ Failed to access NFS${NC}"
        else
            echo "Pod not yet running (Status: $POD_STATUS)"

            # Show detailed pod information for troubleshooting
            echo -e "\n${YELLOW}Pod Details for Troubleshooting:${NC}"
            for pod in client-user10002 client-user10003 client-user10004; do
                if kubectl get pod "$pod" > /dev/null 2>&1; then
                    POD_PHASE=$(kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
                    echo -e "\n${YELLOW}--- Pod: $pod (Status: $POD_PHASE) ---${NC}"

                    if [ "$POD_PHASE" != "Running" ]; then
                        echo "Events and conditions:"
                        kubectl describe pod "$pod" | grep -A 20 "Events:" || echo "No events found"

                        # Check for specific error patterns
                        DESCRIBE_OUTPUT=$(kubectl describe pod "$pod" 2>/dev/null)
                        if echo "$DESCRIBE_OUTPUT" | grep -q "mount.*failed\|nfs.*error\|permission.*denied"; then
                            echo -e "${RED}⚠ NFS mount issues detected${NC}"
                        fi
                        if echo "$DESCRIBE_OUTPUT" | grep -q "image.*pull\|ErrImagePull"; then
                            echo -e "${RED}⚠ Image pull issues detected${NC}"
                        fi
                        if echo "$DESCRIBE_OUTPUT" | grep -q "unbound.*PersistentVolumeClaim"; then
                            echo -e "${RED}⚠ PVC binding issues detected${NC}"
                        fi
                    fi
                fi
            done
        fi
    fi
else
    echo -e "${RED}✗ Kubernetes cluster not accessible${NC}"
fi

# Check VM servers
echo -e "\n${YELLOW}Checking VM servers...${NC}"
echo "NFS Server: ${NFS_SERVER}"
if command -v nc > /dev/null 2>&1; then
    if nc -z "${NFS_SERVER}" 2049 2>/dev/null; then
        echo -e "${GREEN}✓ NFS server port 2049 accessible${NC}"
    else
        echo -e "${RED}✗ NFS server port 2049 not accessible${NC}"
    fi
else
    echo "netcat not available - cannot test NFS port"
fi

echo "KDC Server: ${KDC_SERVER}"
if command -v curl > /dev/null 2>&1; then
    if curl -s --connect-timeout 2 "http://${KDC_SERVER}:8080/" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ KDC HTTP server accessible${NC}"
    else
        echo -e "${RED}✗ KDC server not accessible on port 8080${NC}"
    fi
else
    echo "curl not available - cannot test KDC server"
fi

echo "Logs from krb5-sidecar:"
kubectl logs client-user10002-kcm -c krb5-sidecar
echo

echo "Logs from nfs-client:"
kubectl logs client-user10002-kcm -c nfs-client
echo
