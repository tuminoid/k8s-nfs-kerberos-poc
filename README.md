# NFSv4 + Kerberos in Kubernetes

Multi-machine kubeadm cluster with NFSv4 + Kerberos authentication using KCM sidecar pattern.

## Multi-Machine Quickstart

```bash
# On KDC machine (192.168.1.10):
sudo ./vm-scripts/install-kdc.sh nfs-192.168.1.11.nip.io

# On NFS machine (192.168.1.11):
sudo ./vm-scripts/install-nfs.sh kdc-192.168.1.10.nip.io

# On K8s machine (192.168.1.12):
sudo ./vm-scripts/setup-k8s-node.sh kdc-192.168.1.10.nip.io nfs-192.168.1.11.nip.io

# Deploy applications on K8s machine:
make deploy KDC=kdc-192.168.1.10.nip.io NFS=nfs-192.168.1.11.nip.io

# Test everything:
make test
```

## Single-Machine Quickstart (Legacy)

```bash
make single-node-setup    # Install KDC + NFS + K8s prereqs
make deploy               # Auto-detects local IP for nip.io hostnames
make test                 # Validate everything works
```

## Requirements

- Ubuntu 24.04 VMs with ens3 interface
- Root access, 4GB RAM, 50GB disk per machine
- Network connectivity between machines

## Architecture

**Multi-machine setup:**
- **KDC machine**: Kerberos KDC server (port 88, 8080)
- **NFS machine**: NFS server with Kerberos (port 2049, sec=krb5)
- **K8s machine**: Kubernetes node with client pods

**Using nip.io for hostnames:**
- KDC: `kdc-<ip>.nip.io`
- NFS: `nfs-<ip>.nip.io`
- K8s: `k8s-<ip>.nip.io`

**ConfigMap-based configuration:**
- Hostnames injected via configmaps (no /etc/hosts modification)
- Dynamic PV generation with correct NFS server
- Environment variables from configmaps in pods

## What Gets Deployed

**Host level:**
- KDC server: `kdc.example.com` (port 88, 8080)
- NFS server: `nfs.example.com` (port 2049, sec=krb5)
- Host keytab: `/etc/krb5.keytab` with NFS service principals
- KCM daemon: Credential sharing via Unix socket
- GSS modules + RPC pipefs

**Per-user (3 users: 10002, 10003, 10004):**
- User principals + keytabs from HTTP
- NFS exports with proper UIDs
- PV/PVC + Pod (krb5-sidecar + nfs-client)

**Sidecar:**
- User `kinit` + NFS service tickets
- Credential renewal + KCM integration

## Architecture

Host authenticates NFS mount. Containers authenticate file access.
Auth needs to be in place on the node side when Kubelet mounts the NFS,
otherwise it is stale mount.

## Iteration

```bash
make status   # Check what's running
make clean    # Clean K8s only (keeps NFS + KDC)
make deploy KDC=<kdc_hostname> NFS=<nfs_hostname>  # Redeploy cluster
```

## Files

**VM Setup Scripts:**
- `vm-scripts/install-kdc.sh` - KDC server setup (requires nfs_hostname)
- `vm-scripts/install-nfs.sh` - NFS server setup (requires kdc_hostname)
- `vm-scripts/setup-k8s-node.sh` - K8s node setup (requires kdc_hostname, nfs_hostname)

**Deployment:**
- `deploy-k8s.sh` - K8s deployment (requires kdc_hostname, nfs_hostname)

**Manifests:**
- `k8s-manifests/client-user*-kcm.yaml` - Pod manifests using configmaps
- `k8s-manifests/pvc-user*.yaml` - PVC manifests
- `k8s-manifests/storageclass.yaml` - Storage class
- PVs are generated dynamically with correct NFS hostname

**Key Features:**
- Uses nip.io hostnames instead of /etc/hosts
- ConfigMaps for dynamic hostname configuration
- PVs generated dynamically in deploy script
- Scripts take hostname parameters for multi-machine setup
- **NRI Integration**: Dynamic user creation via NRI hooks (when LOCAL_USERS=false)
- No modification of committed git manifests

## NRI Mode (Dynamic User Creation)

When `LOCAL_USERS=false`, the system uses NRI (Node Runtime Interface) hooks to:
- Dynamically create users when pods are scheduled
- Download keytabs and perform Kerberos authentication before NFS mount
- Clean up users and credentials when pods are deleted

```bash
# Enable NRI mode
export LOCAL_USERS=false
make deploy
```

## File Structure

- `vm-scripts/`: KDC and NFS server setup
- `k8s-manifests/`: PV, PVC, pod definitions, NRI configurations
- `containers/`: Docker images for sidecar + client
- `nri-hooks/`: NRI hook scripts for user management
- `deploy-k8s.sh`: Full cluster deployment
- `test.sh`: Validation suite

## Troubleshooting

```bash
make status                                         # Overall health
kubectl logs client-user10002-kcm -c krb5-sidecar   # Sidecar logs
kubectl logs client-user10002-kcm -c nfs-client     # Client logs
sudo systemctl status kcm                           # KCM daemon
sudo exportfs -v                                    # NFS exports
sudo -u user10002 klist -e                          # User tickets
```

## Common Issues

- KCM socket missing: `ls -la /var/run/kcm.socket`
- GSS modules not loaded: `lsmod | grep gss`
- RPC pipefs not mounted: `mount | grep rpc_pipefs`
- Host keytab missing NFS principals: `klist -k /etc/krb5.keytab`
