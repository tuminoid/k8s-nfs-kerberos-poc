# NFSv4 + Kerberos in Kubernetes

Single-node kubeadm cluster with NFSv4 + Kerberos authentication using KCM sidecar pattern.

## Quickstart

```bash
make setup    # Install KDC + NFS + K8s prereqs
make deploy   # Deploy cluster + applications
make test     # Validate everything works
```

## Requirements

- Ubuntu 24.04 VM with ens3 interface
- Root access, 4GB RAM, 50GB disk

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
make deploy   # Redeploy cluster
```

## Files

- `vm-scripts/`: KDC and NFS server setup
- `k8s-manifests/`: PV, PVC, pod definitions
- `containers/`: Docker images for sidecar + client
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
