#!/usr/bin/env bash

set -eu

# not used by all testing scenarios
USERNAME=${KERBEROS_USER:-user10002}
USER_ID=$(id -u)
REALM=${KERBEROS_REALM:-EXAMPLE.COM}
export KRB5CCNAME=${KRB5CCNAME:-"FILE:/tmp/krb5cc_${USER_ID}"}

echo "Starting NFS client container with FILE credentials..."
echo "Waiting for sidecar to authenticate..."

# Wait for FILE credentials from sidecar
while ! klist 2>/dev/null; do
    echo "Waiting for FILE credentials..."
    sleep 2
done

echo "Checking FILE credentials..."
klist

echo "Testing NFS access..."
ls -la /home/ || echo "Cannot access NFS directory"

echo "Testing NFS write..."
date > /home/test.txt 2>/dev/null && echo "NFS write successful" || echo "Cannot write to NFS"
cat /home/test.txt || echo "Cannot read test file"

echo "Container ready. Keeping alive..."
while true; do
    echo "Sleeping for ${NFS_WRITE_INTERVAL:-300} seconds before next write..."
    sleep "${NFS_WRITE_INTERVAL:-300}"
    date >> /home/test.txt && echo "NFS write successful: $(date)" || echo "failed write to nfs: $(date)"
done
