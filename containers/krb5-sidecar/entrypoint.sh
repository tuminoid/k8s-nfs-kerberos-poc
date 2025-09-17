#!/usr/bin/env bash

# Kerberos sidecar entrypoint script
# Manages Kerberos credentials using FILE-based credential caches

set -eu

USERNAME=${KERBEROS_USER:-user10002}
REALM=${KERBEROS_REALM:-EXAMPLE.COM}
KERBEROS_RENEWAL_TIME=${KERBEROS_RENEWAL_TIME:-86400}
USER_ID=$(id -u)
export KRB5CCNAME=${KRB5CCNAME:-"FILE:/tmp/krb5cc_${USER_ID}"}

echo "Starting Kerberos sidecar for ${USERNAME}@${REALM}"

# Use FILE-based credential cache
echo "Using FILE credential cache: ${KRB5CCNAME}"

echo "Initial tickets:"
klist

# Start credential renewal loop
echo "Starting credential renewal loop (every ${KERBEROS_RENEWAL_TIME} seconds)"
while true; do
    sleep "${KERBEROS_RENEWAL_TIME}"
    echo "Renewing Kerberos credentials..."
    if kinit -R; then
        echo "✓ Credentials renewed successfully"
    else
        echo "⚠ Renewal failed, getting fresh ticket..."
        if kinit -k -t "/etc/keytabs/${USERNAME}.keytab" "${USERNAME}@${REALM}"; then
            echo "✓ Fresh ticket obtained"
        else
            echo "✗ Failed to get fresh ticket"
            exit 1
        fi
    fi
    echo "Current tickets:"
    klist
done
