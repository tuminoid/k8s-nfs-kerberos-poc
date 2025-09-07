#!/usr/bin/env bash

# Kerberos sidecar entrypoint script
# Manages Kerberos credentials using KCM

set -eu

USERNAME=${KERBEROS_USER:-user10002}
REALM=${KERBEROS_REALM:-EXAMPLE.COM}
KERBEROS_RENEWAL_TIME=${KERBEROS_RENEWAL_TIME:-86400}
export KRB5CCNAME=${KRB5CCNAME:-"KCM:"}

echo "Starting Kerberos sidecar for ${USERNAME}@${REALM}"

# Set KCM as credential cache

# Perform initial authentication
echo "Getting initial TGT ticket..."
kinit -k -t /etc/keytabs/${USERNAME}.keytab ${USERNAME}@${REALM}

echo "Initial authentication successful. Tickets:"
klist

# Start credential renewal loop
echo "Starting credential renewal loop (every ${KERBEROS_RENEWAL_TIME} seconds)"
while true; do
    sleep ${KERBEROS_RENEWAL_TIME}
    echo "Renewing Kerberos credentials..."
    kinit -R || {
        echo "Renewal failed, getting fresh ticket..."
        kinit -k -t /etc/keytabs/${USERNAME}.keytab ${USERNAME}@${REALM}
        echo "Re-requesting NFS service ticket after renewal..."
        kvno nfs/nfs.example.com@${REALM} || echo "Warning: Could not get NFS service ticket"
    }
    echo "Credentials renewed. Current tickets:"
    klist
done
