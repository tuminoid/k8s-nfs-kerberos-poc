#!/usr/bin/env bash

set -eu

USER_ID=${KERBEROS_USER:-user10002}
REALM=${KERBEROS_REALM:-EXAMPLE.COM}

echo "Starting NFS client container with KCM..."
echo "Waiting for sidecar to authenticate..."

# Wait for KCM credentials from sidecar
while ! klist 2>/dev/null; do
    echo "Waiting for KCM credentials..."
    sleep 2
done

echo "Checking KCM credentials..."
klist

echo "Testing NFS access..."
ls -la /home/ || echo "Cannot access NFS directory"

echo "Testing NFS write..."
echo "test" > /home/test.txt 2>/dev/null && echo "NFS write successful" || echo "Cannot write to NFS"
cat /home/test.txt || echo "Cannot read test file"

echo "Container ready. Keeping alive..."
tail -f /dev/null
