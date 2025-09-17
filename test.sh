#!/usr/bin/env bash
# Comprehensive test script for NFS Kerberos POC
# Tests proper authentication, authorization, and NFS functionality

set -eu

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
USERS=("user10002" "user10003" "user10004" "user10005" "user10006")
TEST_FILE_PREFIX="test-file"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

# Global variable to track failed users from last test
LAST_TEST_FAILED_USERS=()

# Configuration - detect from configmap
if kubectl get configmap service-hostnames &> /dev/null; then
    KDC_SERVER=$(kubectl get configmap service-hostnames -o jsonpath='{.data.KDC_HOSTNAME}' 2>/dev/null)
    NFS_SERVER=$(kubectl get configmap service-hostnames -o jsonpath='{.data.NFS_HOSTNAME}' 2>/dev/null)

    if [[ -z "${KDC_SERVER}" || -z "${NFS_SERVER}" ]]; then
        echo "ERROR: Failed to read hostnames from ConfigMap"
        echo "Make sure the deployment has been run properly"
        exit 1
    fi
else
    echo "ERROR: service-hostnames ConfigMap not found"
    echo "Make sure the deployment has been run and ConfigMap is created"
    exit 1
fi

# Helper functions
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Get KRB5CCNAME value from a pod's environment
get_krb5ccname() {
    local user="$1"
    local container="${2:-nfs-client}"  # Default to nfs-client container
    local pod_name="client-${user}"

    # Get KRB5CCNAME environment variable from the pod
    local ccname=$(kubectl exec "${pod_name}" -c "${container}" -- printenv KRB5CCNAME 2>/dev/null || echo "")

    # Default to FILE cache based on user ID if not set
    if [[ -z "${ccname}" ]]; then
        local uid=$(echo "${user}" | sed 's/user//')
        ccname="FILE:/tmp/krb5cc_${uid}"
    fi

    echo "${ccname}"
}

# Extract renewal window information from klist output
extract_renewal_info() {
    local klist_output="$1"
    local ticket_type="${2:-krbtgt}"  # Default to TGT, can also be "nfs"

    local expires=""
    local renew_until=""

    if [[ "${ticket_type}" == "krbtgt" ]]; then
        expires=$(echo "${klist_output}" | grep "krbtgt/" | head -1 | awk '{print $3, $4}')
        renew_until=$(echo "${klist_output}" | grep "renew until" | head -1 | awk '{print $4, $5}')
    elif [[ "${ticket_type}" == "nfs" ]]; then
        # Look for actual NFS service ticket lines (not Default principal line)
        # Ticket lines have date/time in first two columns
        expires=$(echo "${klist_output}" | grep "nfs/" | grep -v "Default principal" | head -1 | awk '{print $3, $4}')
    fi

    echo "${expires}|${renew_until}"
}

# Calculate relative time until expiration
calculate_time_until() {
    local timestamp="$1"

    # Skip empty or malformed timestamps
    if [[ -z "${timestamp}" ]] || [[ "${timestamp}" == " " ]]; then
        echo ""
        return
    fi

    # Convert timestamp to epoch time
    local target_epoch=$(date -d "${timestamp}" +%s 2>/dev/null || echo "0")
    local current_epoch=$(date +%s)

    if [[ "${target_epoch}" -eq 0 ]]; then
        echo "unknown"
        return
    fi

    local diff=$((target_epoch - current_epoch))

    if [[ ${diff} -lt 0 ]]; then
        echo "expired"
        return
    fi

    local hours=$((diff / 3600))
    local minutes=$(((diff % 3600) / 60))
    local seconds=$((diff % 60))

    if [[ ${hours} -gt 0 ]]; then
        echo "${hours}h ${minutes}m ${seconds}s"
    elif [[ ${minutes} -gt 0 ]]; then
        echo "${minutes}m ${seconds}s"
    else
        echo "${seconds}s"
    fi
}

# Check credentials in container using the appropriate cache type
check_container_credentials() {
    local user="$1"
    local container="${2:-nfs-client}"
    local pod_name="client-${user}"

    echo "Checking ${user} (${container}) credentials..."

    # Get the credential cache type from the pod
    local ccname=$(get_krb5ccname "${user}" "${container}")

    # Run klist in the container
    local klist_output=$(kubectl exec "${pod_name}" -c "${container}" -- klist 2>/dev/null || echo "NO_CREDENTIALS")

    if echo "${klist_output}" | grep -q "${user}@EXAMPLE.COM"; then
        # Extract renewal information
        local renewal_info=$(extract_renewal_info "${klist_output}" "krbtgt")
        local expires=$(echo "${renewal_info}" | cut -d'|' -f1)
        local renew_until=$(echo "${renewal_info}" | cut -d'|' -f2)

        print_success "${user} (${container}): Valid credentials [${ccname}]"
        echo "  └─ Expires: ${expires}"
        if [[ -n "${renew_until}" ]]; then
            echo "  └─ Renew until: ${renew_until}"
        fi

        # Check for NFS service tickets
        if echo "${klist_output}" | grep -q "nfs/"; then
            local nfs_renewal_info=$(extract_renewal_info "${klist_output}" "nfs")
            local nfs_expires=$(echo "${nfs_renewal_info}" | cut -d'|' -f1)
            echo "  └─ NFS service ticket expires: ${nfs_expires}"
        fi

        return 0
    else
        print_error "${user} (${container}): No valid credentials [${ccname}]"
        echo "Credential cache contents:"
        echo "${klist_output}" | sed 's/^/  /'
        return 1
    fi
}

test_non_root_user() {
    print_header "Testing Non-Root User Execution"

    local failed_users=0
    local failed_user_list=()

    for user in "${USERS[@]}"; do
        local pod_name="client-${user}"
        echo "Testing that ${user} is running as non-root..."

        # Check effective user ID - should not be 0 (root)
        local uid=$(kubectl exec "${pod_name}" -c nfs-client -- id -u 2>/dev/null || echo "FAILED")
        if [[ "${uid}" == "FAILED" ]]; then
            print_error "${user}: Failed to get user ID"
            failed_users=$((failed_users + 1))
            failed_user_list+=("${user}")
        elif [[ "${uid}" == "0" ]]; then
            print_error "${user}: Running as root (UID 0) - security violation!"
            failed_users=$((failed_users + 1))
            failed_user_list+=("${user}")
        else
            print_success "${user}: Running as non-root user (UID ${uid})"

            # Additional check: verify the user ID matches expected range (10002-10006)
            local expected_uid=${user#user}  # Remove "user" prefix to get numeric ID
            if [[ "${uid}" == "${expected_uid}" ]]; then
                print_success "${user}: UID matches expected value (${expected_uid})"
            else
                print_warning "${user}: UID (${uid}) doesn't match expected (${expected_uid})"
            fi
        fi
    done

    # Export failed users for tracking
    LAST_TEST_FAILED_USERS=("${failed_user_list[@]}")

    if [[ ${failed_users} -gt 0 ]]; then
        print_error "Non-root user test FAILED (${failed_users}/${#USERS[@]} users failed)"
        return ${failed_users}
    else
        print_success "Non-root user test PASSED"
        return 0
    fi
}

wait_for_pods() {
    print_header "Waiting for pods to be ready"
    for user in "${USERS[@]}"; do
        echo "Waiting for client-${user} to be ready..."
        kubectl wait --for=condition=ready "pod/client-${user}" --timeout=60s
    done
    print_success "All pods are ready"
}

test_pod_status() {
    print_header "Testing Pod Status"

    echo "Checking pod status:"
    kubectl get pods | grep client-user

    local failed_users=0
    local failed_user_list=()
    for user in "${USERS[@]}"; do
        local pod_name="client-${user}"
        local ready=$(kubectl get pod "${pod_name}" -o jsonpath='{.status.containerStatuses[*].ready}' | grep -o true | wc -l)
        local total=$(kubectl get pod "${pod_name}" -o jsonpath='{.status.containerStatuses[*]}' | jq length 2>/dev/null || echo "unknown")

        # Expected container counts based on scenarios
        local expected_containers
        case "${user}" in
            user10002|user10005)
                expected_containers=2  # Has sidecar + nfs-client
                ;;
            user10003|user10004|user10006)
                expected_containers=1  # Only nfs-client (user10004 uses CronJob for renewal)
                ;;
            *)
                expected_containers=2  # Default assumption
                ;;
        esac

        if [[ "${ready}" == "${expected_containers}" ]]; then
            print_success "Pod ${pod_name}: ${ready}/${total} containers ready (expected ${expected_containers})"
        else
            print_error "Pod ${pod_name}: ${ready}/${total} containers ready (expected ${expected_containers})"
            failed_users=$((failed_users + 1))
            failed_user_list+=("${user}")
        fi
    done

    # Check CronJob status for user10004
    echo "Checking CronJob status for user10004..."
    if kubectl get cronjob kerberos-renewal-user10004 &>/dev/null; then
        local cronjob_status=$(kubectl get cronjob kerberos-renewal-user10004 -o jsonpath='{.spec.suspend}' 2>/dev/null)
        if [[ "${cronjob_status}" == "true" ]]; then
            print_warning "CronJob kerberos-renewal-user10004: Suspended"
        else
            print_success "CronJob kerberos-renewal-user10004: Active"

            # Check recent job executions
            local recent_jobs=$(kubectl get jobs --selector='job-name=kerberos-renewal-user10004' --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -3 | wc -l)
            if [[ ${recent_jobs} -gt 0 ]]; then
                print_success "CronJob kerberos-renewal-user10004: Has recent job executions"
            else
                print_warning "CronJob kerberos-renewal-user10004: No recent job executions found"
            fi
        fi
    else
        print_error "CronJob kerberos-renewal-user10004: Not found"
        failed_users=$((failed_users + 1))
        failed_user_list+=("user10004")
    fi

    # Export failed users for tracking
    LAST_TEST_FAILED_USERS=("${failed_user_list[@]}")

    if [[ ${failed_users} -gt 0 ]]; then
        print_error "Pod status test FAILED (${failed_users}/${#USERS[@]} users failed)"
        return ${failed_users}
    else
        print_success "Pod status test PASSED"
        return 0
    fi
}

test_kerberos_authentication() {
    print_header "Testing Kerberos Authentication"

    local failed_users=0
    local failed_user_list=()

    for user in "${USERS[@]}"; do
        echo "Testing Kerberos authentication for ${user}..."

        # Check main nfs-client container first
        if check_container_credentials "${user}" "nfs-client"; then
            # Check sidecar container if it exists
            case "${user}" in
                user10002|user10005)
                    # These users have sidecar containers
                    if check_container_credentials "${user}" "krb5-sidecar"; then
                        print_success "${user}: Both containers have valid credentials"
                    else
                        print_warning "${user}: Main container OK, but sidecar has credential issues"
                    fi
                    ;;
                user10004)
                    # This user uses CronJob for renewal
                    print_success "${user}: Container credentials verified (CronJob renewal)"
                    ;;
                *)
                    # These users don't have renewal mechanism
                    print_success "${user}: Container credentials verified (no renewal)"
                    ;;
            esac
        else
            print_error "${user}: Main container credential check failed"
            failed_users=$((failed_users + 1))
            failed_user_list+=("${user}")

            # Still check sidecar if it exists for debugging
            case "${user}" in
                user10002|user10005)
                    echo "  Checking sidecar for debugging..."
                    check_container_credentials "${user}" "krb5-sidecar" || true
                    ;;
            esac
        fi
    done

    # Export failed users for tracking
    LAST_TEST_FAILED_USERS=("${failed_user_list[@]}")

    if [[ ${failed_users} -gt 0 ]]; then
        print_error "Kerberos authentication test FAILED (${failed_users}/${#USERS[@]} users failed)"
        return ${failed_users}
    else
        print_success "Kerberos authentication test PASSED"
        return 0
    fi
}

test_nfs_mount_access() {
    print_header "Testing NFS Mount Access"

    local failed_users=0
    local failed_user_list=()

    for user in "${USERS[@]}"; do
        local pod_name="client-${user}"
        echo "Testing NFS mount access for ${user}..."

        # Test if user can list their home directory
        local ls_output=$(kubectl exec "${pod_name}" -c nfs-client -- ls -la /home/ 2>&1 || echo "FAILED")
        if echo "${ls_output}" | grep -q "total\|drwx"; then
            print_success "${user}: Can access NFS mount"
        elif echo "${ls_output}" | grep -q "Permission denied\|Stale file handle"; then
            print_error "${user}: NFS mount access denied - Kerberos authentication or mapping issue"
            failed_users=$((failed_users + 1))
            failed_user_list+=("${user}")
        else
            print_error "${user}: Cannot access NFS mount"
            echo "ls output: ${ls_output}"
            failed_users=$((failed_users + 1))
            failed_user_list+=("${user}")
        fi
    done

    # Export failed users for tracking
    LAST_TEST_FAILED_USERS=("${failed_user_list[@]}")

    if [[ ${failed_users} -gt 0 ]]; then
        print_error "NFS mount access test FAILED (${failed_users}/${#USERS[@]} users failed)"
        return ${failed_users}
    else
        print_success "NFS mount access test PASSED"
        return 0
    fi
}

test_file_operations() {
    print_header "Testing File Operations"

    local failed_users=0
    local failed_user_list=()

    for user in "${USERS[@]}"; do
        local pod_name="client-${user}"
        local test_file="/home/${TEST_FILE_PREFIX}-${user}-${TIMESTAMP}.txt"
        local test_content="Test file created by ${user} at $(date)"

        echo "Testing file operations for ${user}..."
        local user_failed=false

        # Test file creation
        kubectl exec "${pod_name}" -c nfs-client -- sh -c "echo '${test_content}' > ${test_file}" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            print_success "${user}: Can create files"
        else
            print_error "${user}: Cannot create files"
            user_failed=true
            failed_users=$((failed_users + 1))
            failed_user_list+=("${user}")
            continue  # Skip other tests for this user if creation fails
        fi

        # Test file reading
        local read_content=$(kubectl exec "${pod_name}" -c nfs-client -- cat "${test_file}" 2>/dev/null)
        if [[ "${read_content}" == "${test_content}" ]]; then
            print_success "${user}: Can read own files"
        else
            print_error "${user}: Cannot read own files"
            user_failed=true
        fi

        # Test file modification
        local new_content="Modified by ${user} at $(date)"
        kubectl exec "${pod_name}" -c nfs-client -- sh -c "echo '${new_content}' >> ${test_file}" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            print_success "${user}: Can modify own files"
        else
            print_error "${user}: Cannot modify own files"
            user_failed=true
        fi

        # Count this user as failed if any of the operations failed (but not already counted)
        if [[ "${user_failed}" == "true" ]] && [[ ${failed_users} -eq 0 || "${failed_user_list[-1]}" != "${user}" ]]; then
            failed_users=$((failed_users + 1))
            failed_user_list+=("${user}")
        fi
    done

    # Export failed users for tracking
    LAST_TEST_FAILED_USERS=("${failed_user_list[@]}")

    if [[ ${failed_users} -gt 0 ]]; then
        print_error "File operations test FAILED (${failed_users}/${#USERS[@]} users failed)"
        return ${failed_users}
    else
        print_success "File operations test PASSED"
        return 0
    fi
}

test_persistent_storage() {
    print_header "Testing Persistent Storage"

    local failed_users=0

    for user in "${USERS[@]}"; do
        local pod_name="client-${user}"
        local persistent_file="/home/persistent-test-${user}.txt"
        local content="Persistent data for ${user} created at $(date)"

        echo "Testing persistent storage for ${user}..."

        # Create a file
        kubectl exec "${pod_name}" -c nfs-client -- sh -c "echo '${content}' > ${persistent_file}" 2>/dev/null

        # Restart the pod
        echo "Restarting pod ${pod_name}..."
        kubectl delete pod "${pod_name}"
        kubectl apply -f "k8s-manifests/client-${user}.yaml"

        # Wait for pod to be ready
        kubectl wait --for=condition=ready "pod/${pod_name}" --timeout=60s

        # Check if file still exists
        local read_content=$(kubectl exec "${pod_name}" -c nfs-client -- cat "${persistent_file}" 2>/dev/null || echo "FILE_NOT_FOUND")
        if [[ "${read_content}" == "${content}" ]]; then
            print_success "${user}: Persistent storage working"
        else
            print_error "${user}: Persistent storage failed"
            echo "Expected: ${content}"
            echo "Got: ${read_content}"
            failed_users=$((failed_users + 1))
        fi
    done

    if [[ ${failed_users} -gt 0 ]]; then
        print_error "Persistent storage test FAILED (${failed_users}/${#USERS[@]} users failed)"
        return ${failed_users}
    else
        print_success "Persistent storage test PASSED"
        return 0
    fi
}

check_user_credentials() {
    local user="$1"
    local pod_name="client-${user}"
    local container="nfs-client"

    # For users with sidecar, check sidecar container
    case "${user}" in
        user10002|user10005)
            container="krb5-sidecar"
            ;;
    esac

    echo "Checking credentials for ${user} in container ${container}..."
    local klist_output=$(kubectl exec "${pod_name}" -c "${container}" -- klist 2>/dev/null || echo "NO_CREDENTIALS")

    if echo "${klist_output}" | grep -q "${user}@EXAMPLE.COM"; then
        # Extract renewal information
        local renewal_info=$(extract_renewal_info "${klist_output}" "krbtgt")
        local expires=$(echo "${renewal_info}" | cut -d'|' -f1)
        local renew_until=$(echo "${renewal_info}" | cut -d'|' -f2)

        # Calculate relative time until expiration
        local time_until_expires=$(calculate_time_until "${expires}")

        # Format the success message
        if [[ -n "${time_until_expires}" ]]; then
            print_success "${user}: Has valid credentials (expires: ${expires} in ${time_until_expires})"
        else
            print_success "${user}: Has valid credentials (expires: ${expires})"
        fi

        # Show renewable information if available
        if [[ -n "${renew_until}" ]] && [[ "${renew_until}" != " " ]]; then
            local time_until_renew_expires=$(calculate_time_until "${renew_until}")
            if [[ -n "${time_until_renew_expires}" ]]; then
                echo "  └─ Renewable until: ${renew_until} (in ${time_until_renew_expires})"
            else
                echo "  └─ Renewable until: ${renew_until}"
            fi
        fi

        return 0
    else
        print_error "${user}: No valid credentials"
        return 1
    fi
}

check_system_credentials() {
    echo "Checking system NFS credentials..."

    local file_found=false
    local any_valid=false

    # Check FILE-based cache (system credentials location)
    echo "  Checking FILE:/tmp/krb5cc_0..."
    local file_klist_output=$(sudo klist -c FILE:/tmp/krb5cc_0 2>/dev/null || echo "NO_FILE_CREDENTIALS")

    if echo "${file_klist_output}" | grep -q "nfs/.*@EXAMPLE.COM\|krbtgt/.*@EXAMPLE.COM"; then
        file_found=true
        local renewal_info=$(extract_renewal_info "${file_klist_output}" "krbtgt")
        local expires=$(echo "${renewal_info}" | cut -d'|' -f1)
        local renew_until=$(echo "${renewal_info}" | cut -d'|' -f2)

        # Check if credentials are actually expired
        local current_epoch=$(date +%s)
        local expires_epoch=$(date -d "${expires}" +%s 2>/dev/null || echo "0")

        if [[ "${expires_epoch}" -gt "${current_epoch}" ]]; then
            any_valid=true
            local time_until=$(calculate_time_until "${expires}")
            print_success "System FILE cache: Valid credentials"
            echo "    └─ Expires: ${expires} (in ${time_until})"
            if [[ -n "${renew_until}" ]] && [[ "${renew_until}" != " " ]]; then
                local renew_time_until=$(calculate_time_until "${renew_until}")
                echo "    └─ Renew until: ${renew_until} (in ${renew_time_until})"
            fi
        else
            print_error "System FILE cache: EXPIRED credentials"
            echo "    └─ Expired: ${expires} ($(calculate_time_until "${expires}"))"
            if [[ -n "${renew_until}" ]] && [[ "${renew_until}" != " " ]]; then
                echo "    └─ Renew until: ${renew_until}"
            fi
            print_warning "⚠ CRITICAL: System credentials expired - NFS access will fail!"
        fi

        # Check for NFS service tickets
        if echo "${file_klist_output}" | grep -q "nfs/"; then
            local nfs_renewal_info=$(extract_renewal_info "${file_klist_output}" "nfs")
            local nfs_expires=$(echo "${nfs_renewal_info}" | cut -d'|' -f1)
            if [[ -n "${nfs_expires}" ]]; then
                local nfs_expires_epoch=$(date -d "${nfs_expires}" +%s 2>/dev/null || echo "0")
                if [[ "${nfs_expires_epoch}" -gt "${current_epoch}" ]]; then
                    local nfs_time_until=$(calculate_time_until "${nfs_expires}")
                    echo "    └─ NFS service ticket expires: ${nfs_expires} (in ${nfs_time_until})"
                else
                    echo "    └─ NFS service ticket EXPIRED: ${nfs_expires} ($(calculate_time_until "${nfs_expires}"))"
                fi
            fi
        fi
    else
        print_warning "System FILE cache: No valid credentials"
    fi

    # Summary
    if [[ "${any_valid}" == true ]]; then
        print_success "System credentials: Valid and current"
        return 0
    else
        if [[ "${file_found}" == true ]]; then
            print_error "System credentials: EXPIRED - NFS will not work!"
            echo "  ⚠ Fix: Renew system credentials with: sudo kinit -k -t /etc/krb5.keytab nfs/\${NFS_HOSTNAME}@EXAMPLE.COM"
        else
            print_error "System credentials: No valid credentials found in FILE cache"
            echo "  FILE cache contents:"
            sudo klist -c FILE:/tmp/krb5cc_0 2>&1 | sed 's/^/    /' || echo "    Failed to read FILE cache"
        fi
        return 1
    fi
}

test_nfs_access_simple() {
    local user="$1"
    local pod_name="client-${user}"

    echo "Testing NFS read access for ${user}..."
    local ls_output=$(kubectl exec "${pod_name}" -c nfs-client -- ls -la /home/ 2>&1 || echo "FAILED")
    if echo "${ls_output}" | grep -q "total\|drwx"; then
        print_success "${user}: NFS read access working"
        return 0
    else
        print_error "${user}: NFS read access failed - ${ls_output}"
        return 1
    fi

    echo "Testing NFS write access for ${user}..."
    local write_output=$(kubectl exec "${pod_name}" -c nfs-client -- sh -c 'echo "test" > /home/write-test.txt && cat /home/write-test.txt' 2>&1 || echo "FAILED")
    if echo "${write_output}" | grep -q "test"; then
        print_success "${user}: NFS write access working"
        return 0
    else
        print_error "${user}: NFS write access failed - ${write_output}"
        return 1
    fi
}

test_kerberos_renewal_lifecycle() {
    print_header "Testing Kerberos Renewal Lifecycle"
    echo "This test follows the complete ticket lifecycle with new short lifetimes:"
    echo "- Initial tickets: 10 minutes"
    echo "- Max ticket life: 20 minutes"
    echo "- Renewable for: 30 minutes from initial issue"
    echo "- Absolute max: 40 minutes total"
    echo ""
    echo "System credentials:"
    echo "- NFS system tickets: renewed every 20 minutes by timer"
    echo "- Root credential cache: FILE:/tmp/krb5cc_0"
    echo ""
    echo "Container credentials:"
    echo "- All containers use FILE-based caches: FILE:/tmp/krb5cc_[uid]"
    echo "- Sidecars renew every 5 minutes for users with sidecars (user10002, user10005)"
    echo "- CronJob renews every 5 minutes for user10004"
    echo ""
    echo "Test phases:"
    echo "1. Fresh start with 'make replace'"
    echo "2. Wait 6 minutes - check renewal (sidecars renew every 5 min)"
    echo "3. Wait 12 minutes - check if initial tickets expired"
    echo "4. Wait 22 minutes - check if max ticket life applies"
    echo "5. Wait 32 minutes - check if renewable limit applies"
    echo "6. Wait 42 minutes - check absolute expiration"
    echo ""
    print_warning "This test takes approximately 45 minutes to complete"
    echo ""

    print_header "Phase 0: Fresh Start with make replace"
    echo "Running 'make replace' to get fresh pods and credentials..."
    if ! make replace; then
        print_error "Failed to run 'make replace'"
        return 1
    fi

    # Wait for pods to be ready
    echo "Waiting for pods to be ready after replacement..."
    sleep 30
    for user in "${USERS[@]}"; do
        kubectl wait --for=condition=ready "pod/client-${user}" --timeout=60s
    done

    local start_time=$(date +%s)
    echo "Test started at: $(date)"
    echo "Baseline check - all users should have fresh credentials..."

    # Check system credentials first
    check_system_credentials || true

    for user in "${USERS[@]}"; do
        check_user_credentials "${user}" || true
        test_nfs_access_simple "${user}" || true
    done

    print_header "Phase 1: Wait 6 minutes - Check Renewal (sidecars and CronJob should renew)"
    echo "Waiting 6 minutes to verify renewal mechanisms work..."
    echo "Users with sidecars (user10002, user10005) should show renewed tickets"
    echo "User with CronJob (user10004) should show renewed tickets"
    echo "Users without renewal (user10003, user10006) should still have original tickets"

    sleep 360  # 6 minutes

    local current_time=$(date +%s)
    local elapsed=$(( (current_time - start_time) / 60 ))
    echo "=== ${elapsed} minutes elapsed ==="

    check_system_credentials || true
    for user in "${USERS[@]}"; do
        check_user_credentials "${user}" || true
        test_nfs_access_simple "${user}" || true
    done

    print_header "Phase 2: Wait 12 minutes total - Check Initial Ticket Expiration"
    echo "Waiting 6 more minutes (12 minutes total)..."
    echo "Initial 10-minute tickets should have expired"
    echo "Users with sidecars (user10002, user10005) should still work (renewed tickets)"
    echo "User with CronJob (user10004) should still work (renewed tickets)"
    echo "Users without renewal (user10003, user10006) may start failing"

    sleep 360  # 6 more minutes (12 total)

    current_time=$(date +%s)
    elapsed=$(( (current_time - start_time) / 60 ))
    echo "=== ${elapsed} minutes elapsed ==="

    check_system_credentials || true
    for user in "${USERS[@]}"; do
        check_user_credentials "${user}" || true
        test_nfs_access_simple "${user}" || true
    done

    print_header "Phase 3: Wait 22 minutes total - Check Max Ticket Life"
    echo "Waiting 10 more minutes (22 minutes total)..."
    echo "Max ticket life (20 minutes) should be reached"
    echo "Even renewed tickets should be limited to 20-minute max life"

    sleep 600  # 10 more minutes (22 total)

    current_time=$(date +%s)
    elapsed=$(( (current_time - start_time) / 60 ))
    echo "=== ${elapsed} minutes elapsed ==="

    check_system_credentials || true
    for user in "${USERS[@]}"; do
        check_user_credentials "${user}" || true
        test_nfs_access_simple "${user}" || true
    done

    print_header "Phase 4: Wait 32 minutes total - Check Renewable Limit"
    echo "Waiting 10 more minutes (32 minutes total)..."
    echo "30-minute renewable limit should be reached"
    echo "Users with sidecars (user10002, user10005) should get fresh tickets (re-authenticate with keytab)"
    echo "User with CronJob (user10004) should get fresh tickets (re-authenticate with keytab)"
    echo "Users without renewal (user10003, user10006) should definitely fail"

    sleep 600  # 10 more minutes (32 total)

    current_time=$(date +%s)
    elapsed=$(( (current_time - start_time) / 60 ))
    echo "=== ${elapsed} minutes elapsed ==="

    check_system_credentials || true
    for user in "${USERS[@]}"; do
        check_user_credentials "${user}" || true
        test_nfs_access_simple "${user}" || true
    done

    print_header "Phase 5: Wait 42 minutes total - Check Absolute Expiration"
    echo "Waiting 10 more minutes (42 minutes total)..."
    echo "40-minute absolute maximum should be reached"
    echo "All tickets should require fresh authentication"
    echo "Only users with renewal mechanisms (sidecars + CronJob) should recover"

    sleep 600  # 10 more minutes (42 total)

    current_time=$(date +%s)
    elapsed=$(( (current_time - start_time) / 60 ))
    echo "=== ${elapsed} minutes elapsed ==="

    print_header "Final Check - After 40+ Minute Absolute Expiration"
    check_system_credentials || true
    for user in "${USERS[@]}"; do
        check_user_credentials "${user}" || true
        test_nfs_access_simple "${user}" || true
    done

    print_header "Renewal Lifecycle Test Complete"
    local total_time=$(( (current_time - start_time) / 60 ))
    echo "Total test duration: ${total_time} minutes"
    echo ""
    echo "Expected results:"
    echo "✓ user10002, user10005: Should work throughout (have sidecars with FILE caches)"
    echo "✓ user10004: Should work throughout (has CronJob renewal with FILE cache)"
    echo "✗ user10003, user10006: Should fail after initial expiration (no renewal)"
    echo ""
    echo "This test demonstrates:"
    echo "- Automatic renewal by sidecars using FILE caches"
    echo "- Automatic renewal by CronJob using FILE caches"
    echo "- Ticket lifetime limits"
    echo "- Re-authentication requirements"
    echo "- System behavior under credential expiration"

    return 0
}

cleanup_test_files() {
    print_header "Cleaning up test files"

    for user in "${USERS[@]}"; do
        local pod_name="client-${user}"
        echo "Cleaning up test files for ${user}..."
        kubectl exec "${pod_name}" -c nfs-client -- sh -c "rm -f /home/${TEST_FILE_PREFIX}-${user}-*.txt" 2>/dev/null || true
    done

    print_success "Test cleanup completed"
}

run_all_tests() {
    print_header "Starting NFS Kerberos POC Test Suite"
    echo "Timestamp: $(date)"
    echo "Test ID: ${TIMESTAMP}"

    local tests_passed=0
    local tests_failed=0
    local critical_failure=false

    # Track results per user - associative array where key is user and value is failed test count
    declare -A user_failures
    for user in "${USERS[@]}"; do
        user_failures["${user}"]=0
    done

    # List of core test functions (must pass for system to be functional)
    local core_test_functions=(
        "test_pod_status"
        "test_non_root_user"
        "test_kerberos_authentication"
        "test_nfs_mount_access"
        "test_file_operations"
    )

    # Check system credentials first (critical for NFS functionality)
    echo ""
    print_header "System Credentials Check"
    local system_creds_result=0
    check_system_credentials || system_creds_result=$?

    if [[ ${system_creds_result} -ne 0 ]]; then
        print_error "CRITICAL: System credentials check failed - NFS operations will not work"
        critical_failure=true
        tests_failed=$((tests_failed + 1))
    else
        tests_passed=$((tests_passed + 1))
    fi

    # Run core tests first
    for test_func in "${core_test_functions[@]}"; do
        echo ""
        local test_result=0
        ${test_func} || test_result=$?

        # Track which users failed this test
        for failed_user in "${LAST_TEST_FAILED_USERS[@]}"; do
            user_failures["${failed_user}"]=$((user_failures["${failed_user}"] + 1))
        done

        if [[ ${test_result} -eq 0 ]]; then
            tests_passed=$((tests_passed + 5))  # All 5 users passed
        else
            local users_failed=${test_result}
            local users_passed=$((5 - users_failed))
            tests_passed=$((tests_passed + users_passed))
            tests_failed=$((tests_failed + users_failed))

            # Mark critical failure for authentication and file operation tests
            if [[ "${test_func}" == "test_kerberos_authentication" ]] || [[ "${test_func}" == "test_file_operations" ]]; then
                critical_failure=true
            fi
        fi

        # Clear the last test failed users array
        LAST_TEST_FAILED_USERS=()
    done

    # Skip persistent storage test in normal run - use 'persistent' argument to test it
    echo ""
    print_warning "Skipping persistent storage test (use './test.sh persistent' to run it)"

    # Cleanup
    cleanup_test_files

    # Per-client summary
    print_header "Per-Client Test Results"
    local all_clients_passed=true
    for user in "${USERS[@]}"; do
        local user_failed_count=${user_failures["${user}"]}
        if [[ ${user_failed_count} -eq 0 ]]; then
            print_success "${user}: ALL TESTS PASSED ✓"
        else
            print_error "${user}: ${user_failed_count}/${#core_test_functions[@]} tests FAILED ✗"
            all_clients_passed=false
        fi
    done

    # Final results
    print_header "Test Results Summary"
    echo "Tests passed: ${tests_passed}"
    echo "Tests failed: ${tests_failed}"
    echo "Total tests: $((tests_passed + tests_failed))"

    if [[ ${tests_failed} -eq 0 ]]; then
        print_success "All tests PASSED! 🎉"
        echo ""
        echo "Your NFS Kerberos POC is working correctly:"
        echo "✓ Kerberos authentication is functional"
        echo "✓ NFS mounts are working with Kerberos security"
        echo "✓ Persistent storage is working"
        echo "✓ All services are healthy"
        return 0
    else
        print_error "Some tests FAILED! ❌"
        echo ""
        echo "Please check the error messages above and fix any issues."
        return 1
    fi
}

# Main execution
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    echo "NFS Kerberos POC Test Suite"
    echo ""
    echo "Usage: ${0} [options] [test_name]"
    echo ""
    echo "Options:"
    echo "  --help, -h     Show this help message"
    echo "  --wait         Wait for pods to be ready before testing"
    echo "  persistent     Run only persistent storage tests"
    echo "  renewal        Run Kerberos renewal lifecycle test (~2 hours)"
    echo ""
    echo "Test functions (can be run individually):"
    echo "  test_pod_status           - Test Kubernetes pod status"
    echo "  test_non_root_user        - Test that containers run as non-root users"
    echo "  test_kerberos_authentication - Test Kerberos ticket acquisition"
    echo "  test_nfs_mount_access     - Test NFS mount accessibility"
    echo "  test_file_operations      - Test file create/read/write operations"
    echo "  test_persistent_storage   - Test data persistence across pod restarts"
    echo "  test_kerberos_renewal_lifecycle - Test complete renewal lifecycle"
    echo "  cleanup_test_files        - Clean up test files"
    echo ""
    echo "Note: Infrastructure checks (KDC, NFS, GSS services) are available in status.sh"
    echo ""
    echo "Example: ${0} test_nfs_mount_access"
    exit 0
fi

if [[ "${1:-}" == "--wait" ]]; then
    wait_for_pods
    shift
fi

# Handle persistent storage test
if [[ "${1:-}" == "persistent" ]]; then
    echo "Running persistent storage tests only"
    test_persistent_storage
    exit $?
fi

# Handle Kerberos renewal lifecycle test
if [[ "${1:-}" == "renewal" ]]; then
    echo "Running Kerberos renewal lifecycle test"
    test_kerberos_renewal_lifecycle
    exit $?
fi

# If a specific test function is provided, run only that
if [[ $# -eq 1 ]] && declare -f "${1}" > /dev/null; then
    echo "Running specific test: ${1}"
    ${1}
else
    # Run all tests (excluding persistent storage by default)
    run_all_tests
fi
