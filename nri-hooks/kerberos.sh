#!/usr/bin/env bash
# NRI Pre-Create Hook: Setup Kerberos auth before pod creation
# This script runs on the host before kubelet creates the pod
# It must complete successfully for the pod to be created

set -euo pipefail

USER_ID="${1:?}"
GROUP_ID="${2:?}"
FSID="${3:?}"
USERNAME="${4:?}"
REALM="${5:?}"
KDC_HOSTNAME="${6:?}"
NFS_HOSTNAME="${7:?}"  # Not used here, but could be for mount options

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a /var/log/nri-kerberos.log
}

log "Setting up Kerberos authentication for ${USERNAME} (UID: ${USER_ID}, GID: ${GROUP_ID})"
log "Using KDC: ${KDC_HOSTNAME}, Realm: ${REALM}"

# Create keytabs directory if it doesn't exist
KEYTAB_DIR="/etc/keytabs"
mkdir -p "${KEYTAB_DIR}"

# Download keytab for the user
KEYTAB_FILE="${KEYTAB_DIR}/${USERNAME}.keytab"
KEYTAB_URL="http://${KDC_HOSTNAME}:8080/keytabs/${USERNAME}.keytab"

log "Downloading keytab from: ${KEYTAB_URL}"

# Download keytab with retries
for attempt in {1..3}; do
    if curl -f -s -o "${KEYTAB_FILE}" "${KEYTAB_URL}"; then
        log "Successfully downloaded keytab for ${USERNAME}"
        break
    else
        log "Attempt ${attempt}: Failed to download keytab for $USERNAME"
        if [[ "${attempt}" -eq 3 ]]; then
            log "ERROR: Failed to download keytab after 3 attempts"
            exit 1
        fi
        sleep 2
    fi
done

# Set proper permissions on keytab
log "Set keytab permissions"
chmod 600 "${KEYTAB_FILE}"
chown "${USER_ID}:${GROUP_ID}" "${KEYTAB_FILE}"

# Perform kinit as root, then chown to correct UID/GID
log "Performing kinit for ${USERNAME}"

# Create credential cache using the standard location
CC_FILE="/tmp/krb5cc_${USER_ID}"

# Run kinit as root with the keytab
if KRB5CCNAME="FILE:${CC_FILE}" kinit -k -t "${KEYTAB_FILE}" "${USERNAME}@${REALM}"; then
    log "Successfully authenticated ${USERNAME} with Kerberos"

    # Change ownership to the correct UID/GID (even without local users)
    chown "${USER_ID}:${GROUP_ID}" "${CC_FILE}"
    log "Set credential cache ownership to ${USER_ID}:${GROUP_ID}"

    # Verify we have tickets
    if KRB5CCNAME="FILE:${CC_FILE}" klist >/dev/null 2>&1; then
        log "Verified Kerberos tickets for ${USERNAME}"
    else
        log "WARNING: kinit succeeded but no tickets found"
    fi
else
    log "ERROR: Failed to authenticate ${USERNAME} with Kerberos"
    exit 1
fi

log "Successfully completed pre-create setup for ${USERNAME}"

exit 0

# make separate script for this
if [[ "${1:-}" = "stop" ]]; then
    # This does not really work if multiple pods for same user are created
    # TBD: drop stop handling?
    log "Nuking Kerberos tickets for ${USERNAME}"
    rm -f "${USER_FLAG_DIR}/${USERNAME}.created"
    KRB5CCNAME="FILE:${CC_FILE}" kdestroy || true
    rm -f /tmp/krb5cc_${USER_ID}*
fi
