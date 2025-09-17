# NFSv4 + Kerberos in Kubernetes

Kubeadm cluster with NFSv4 + Kerberos authentication.

## Setup

Setup requires three Ubuntu 24.04 VMs with root access, 4GB RAM, 50GB disk each.
Single node setup is not supported to avoid taking shortcuts that would not work
in real world.

```bash
# On KDC machine (192.168.1.10):
make install KDC=192.168.1.10 NFS=192.168.1.11 K8S=192.168.1.12 ROLE=kdc

# On NFS machine (192.168.1.11):
make install KDC=192.168.1.10 NFS=192.168.1.11 K8S=192.168.1.12 ROLE=nfs

# On K8s machine (192.168.1.12):
make install KDC=192.168.1.10 NFS=192.168.1.11 K8S=192.168.1.12 ROLE=k8s

# Deploy applications on K8s machine:
make deploy KDC=kdc-192.168.1.10.nip.io NFS=nfs-192.168.1.11.nip.io

# Test everything:
make test

# Test specific scenarios:
make test-persistent    # Test data persistence across pod restarts
make test-renewal      # Test Kerberos renewal lifecycle (~2 hours)
```

## Architecture

**Components:**
- **KDC machine**: Kerberos KDC server
- **NFS machine**: NFS server with Kerberos
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

**Per-user (5 users: user id's from 10002 to 10006):**
- User principals + keytabs from HTTP
- NFS exports with proper UIDs
- PV/PVC + Pod
- See `nri.io/kerberos-scenario` annotation for pod scenario

**Sidecar:**
- Credential renewal with FILE-based credential caches

## Architecture

Host authenticates NFS mount. Containers authenticate file access.
Auth needs to be in place on the node side when Kubelet mounts the NFS,
otherwise it is stale mount. This is dynamically handled by custom NRI plugin,
that gets keytab from pod annotation, creates user, gets ticket and preps
everything for container runtime to be able to do successful mount.

## Iteration

```bash
make status                                      # Check what's running
make clean                                       # Clean kubeadm K8s cluster, and tickets etc
make deploy KDC=<kdc_hostname> NFS=<nfs_hostname>  # Deploy cluster

# Testing options:
make test                # Full test suite (5 minutes)
make test-persistent     # Test data persistence across pod restarts
make test-renewal        # Test Kerberos renewal lifecycle (~2 hours)
```

## Files

**VM Setup Scripts:**
- `vm-scripts/install-kdc.sh` - KDC server setup (requires nfs_hostname)
- `vm-scripts/install-nfs.sh` - NFS server setup (requires kdc_hostname)
- `vm-scripts/install-k8s.sh` - K8s node setup (requires kdc_hostname, nfs_hostname)

**Deployment:**
- `deploy-k8s.sh` - K8s deployment (requires kdc_hostname, nfs_hostname)

**Manifests:**
- `k8s-manifests/client-user*.yaml` - Pod manifests using configmaps
- `k8s-manifests/storageclass.yaml` - Storage class
- PVs and PVCs are generated dynamically with correct NFS hostname

## NRI Mode (Dynamic User Ticket Management)

The system uses NRI (Node Resource Interface) plugin to:
- Download keytabs and perform Kerberos authentication before NFS mount happens
- Secure keytabs and credentials to the pod user id
- Clean up users and credentials when pods are deleted (TBD)

## File Structure

- `vm-scripts/`: KDC and NFS server setup
- `k8s-manifests/`: PV, PVC, pod definitions, NRI configurations
- `containers/`: Docker images for sidecar + client
- `nri-plugin`: custom Kerberos auth'ing NRI plugin
- `nri-hooks/`: NRI hook scripts for user management
- `deploy-k8s.sh`: Full cluster deployment
- `status.sh`: K8s node status check
- `test.sh`: Validation suite

## Troubleshooting

```bash
make status                                         # Overall health
kubectl logs client-user10002 -c krb5-sidecar       # Sidecar logs
kubectl logs client-user10002 -c nfs-client         # Client logs
sudo systemctl status rpc-gssd                      # GSS daemon
sudo exportfs -v                                    # NFS exports
sudo -u user10002 klist -e                          # User tickets
```

## Common Issues

- FILE credential caches missing: `ls -la /tmp/krb5cc_*`
- GSS modules not loaded: `lsmod | grep gss`
- RPC pipefs not mounted: `mount | grep rpc_pipefs`
- Host keytab missing NFS principals: `klist -k /etc/krb5.keytab`
