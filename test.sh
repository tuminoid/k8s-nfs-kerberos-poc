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
USERS=("user10002" "user10003" "user10004")
TEST_FILE_PREFIX="test-file"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

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

wait_for_pods() {
    print_header "Waiting for pods to be ready"
    for user in "${USERS[@]}"; do
        echo "Waiting for client-${user}-kcm to be ready..."
        kubectl wait --for=condition=ready pod/client-${user}-kcm --timeout=60s
    done
    print_success "All pods are ready"
}

test_pod_status() {
    print_header "Testing Pod Status"

    echo "Checking pod status:"
    kubectl get pods | grep client-user

    local all_ready=true
    for user in "${USERS[@]}"; do
        local pod_name="client-${user}-kcm"
        local ready=$(kubectl get pod $pod_name -o jsonpath='{.status.containerStatuses[*].ready}' | grep -o true | wc -l)
        local total=$(kubectl get pod $pod_name -o jsonpath='{.status.containerStatuses[*]}' | jq length 2>/dev/null || echo "2")

        if [ "$ready" = "2" ]; then
            print_success "Pod $pod_name: $ready/$total containers ready"
        else
            print_error "Pod $pod_name: $ready/$total containers ready"
            all_ready=false
        fi
    done

    if [ "$all_ready" = true ]; then
        print_success "Pod status test PASSED"
    else
        print_error "Pod status test FAILED"
        return 1
    fi
}

test_kerberos_authentication() {
    print_header "Testing Kerberos Authentication"

    for user in "${USERS[@]}"; do
        local pod_name="client-${user}-kcm"
        echo "Testing Kerberos authentication for $user..."

        # Check if sidecar can get tickets
        local klist_output=$(kubectl exec $pod_name -c krb5-sidecar -- klist 2>/dev/null || echo "FAILED")
        if echo "$klist_output" | grep -q "${user}@EXAMPLE.COM"; then
            print_success "$user: Kerberos authentication working"
        else
            print_error "$user: Kerberos authentication failed"
            echo "klist output: $klist_output"
            return 1
        fi
    done

    print_success "Kerberos authentication test PASSED"
}

test_nfs_mount_access() {
    print_header "Testing NFS Mount Access"

    for user in "${USERS[@]}"; do
        local pod_name="client-${user}-kcm"
        echo "Testing NFS mount access for $user..."

        # Test if user can list their home directory
        local ls_output=$(kubectl exec $pod_name -c nfs-client -- ls -la /home/ 2>&1 || echo "FAILED")
        if echo "$ls_output" | grep -q "total\|drwx"; then
            print_success "$user: Can access NFS mount"
        elif echo "$ls_output" | grep -q "Permission denied\|Stale file handle"; then
            print_error "$user: NFS mount access denied - Kerberos authentication or mapping issue"
            return 1
        else
            print_error "$user: Cannot access NFS mount"
            echo "ls output: $ls_output"
            return 1
        fi
    done

    print_success "NFS mount access test PASSED"
}

test_file_operations() {
    print_header "Testing File Operations"

    for user in "${USERS[@]}"; do
        local pod_name="client-${user}-kcm"
        local test_file="/home/${TEST_FILE_PREFIX}-${user}-${TIMESTAMP}.txt"
        local test_content="Test file created by $user at $(date)"

        echo "Testing file operations for $user..."

        # Test file creation
        kubectl exec $pod_name -c nfs-client -- sh -c "echo '$test_content' > $test_file" 2>/dev/null
        if [ $? -eq 0 ]; then
            print_success "$user: Can create files"
        else
            print_error "$user: Cannot create files"
            return 1
        fi

        # Test file reading
        local read_content=$(kubectl exec $pod_name -c nfs-client -- cat $test_file 2>/dev/null)
        if [ "$read_content" = "$test_content" ]; then
            print_success "$user: Can read own files"
        else
            print_error "$user: Cannot read own files"
            return 1
        fi

        # Test file modification
        local new_content="Modified by $user at $(date)"
        kubectl exec $pod_name -c nfs-client -- sh -c "echo '$new_content' >> $test_file" 2>/dev/null
        if [ $? -eq 0 ]; then
            print_success "$user: Can modify own files"
        else
            print_error "$user: Cannot modify own files"
            return 1
        fi
    done

    print_success "File operations test PASSED"
}

test_persistent_storage() {
    print_header "Testing Persistent Storage"

    for user in "${USERS[@]}"; do
        local pod_name="client-${user}-kcm"
        local persistent_file="/home/persistent-test-${user}.txt"
        local content="Persistent data for $user created at $(date)"

        echo "Testing persistent storage for $user..."

        # Create a file
        kubectl exec $pod_name -c nfs-client -- sh -c "echo '$content' > $persistent_file" 2>/dev/null

        # Restart the pod
        echo "Restarting pod $pod_name..."
        kubectl delete pod $pod_name
        kubectl apply -f k8s-manifests/client-${user}-kcm.yaml

        # Wait for pod to be ready
        kubectl wait --for=condition=ready pod/$pod_name --timeout=60s

        # Check if file still exists
        local read_content=$(kubectl exec $pod_name -c nfs-client -- cat $persistent_file 2>/dev/null || echo "FILE_NOT_FOUND")
        if [ "$read_content" = "$content" ]; then
            print_success "$user: Persistent storage working"
        else
            print_error "$user: Persistent storage failed"
            echo "Expected: $content"
            echo "Got: $read_content"
            return 1
        fi
    done

    print_success "Persistent storage test PASSED"
}

test_service_health() {
    print_header "Testing Service Health"

    # Test KDC
    echo "Testing KDC service..."
    if sudo systemctl is-active --quiet krb5-kdc; then
        print_success "KDC service is running"
    else
        print_error "KDC service is not running"
        return 1
    fi

    # Test NFS server
    echo "Testing NFS server..."
    if sudo systemctl is-active --quiet nfs-kernel-server; then
        print_success "NFS server is running"
    else
        print_error "NFS server is not running"
        return 1
    fi

    # Test GSS daemon
    echo "Testing GSS daemon..."
    if sudo systemctl is-active --quiet rpc-gssd; then
        print_success "GSS daemon is running"
    else
        print_error "GSS daemon is not running"
        return 1
    fi

    # Test NFS exports
    echo "Testing NFS exports..."
    local exports=$(showmount -e localhost 2>/dev/null | wc -l)
    if [ "$exports" -gt 1 ]; then
        print_success "NFS exports are available ($((exports-1)) exports)"
    else
        print_error "No NFS exports found"
        return 1
    fi

    print_success "Service health test PASSED"
}

cleanup_test_files() {
    print_header "Cleaning up test files"

    for user in "${USERS[@]}"; do
        local pod_name="client-${user}-kcm"
        echo "Cleaning up test files for $user..."
        kubectl exec $pod_name -c nfs-client -- sh -c "rm -f /home/${TEST_FILE_PREFIX}-${user}-*.txt" 2>/dev/null || true
    done

    print_success "Test cleanup completed"
}

run_all_tests() {
    print_header "Starting NFS Kerberos POC Test Suite"
    echo "Timestamp: $(date)"
    echo "Test ID: $TIMESTAMP"

    local tests_passed=0
    local tests_failed=0
    local critical_failure=false

    # List of core test functions (must pass for system to be functional)
    local core_test_functions=(
        "test_service_health"
        "test_pod_status"
        "test_kerberos_authentication"
        "test_nfs_mount_access"
        "test_file_operations"
    )

    # Run core tests first
    for test_func in "${core_test_functions[@]}"; do
        echo ""
        if $test_func; then
            tests_passed=$((tests_passed + 1))
        else
            tests_failed=$((tests_failed + 1))
            # Mark critical failure for authentication and file operation tests
            if [[ "$test_func" == "test_kerberos_authentication" || "$test_func" == "test_file_operations" ]]; then
                critical_failure=true
            fi
        fi
    done

    # Only run persistent storage test if core functionality is working
    echo ""
    if [ "$critical_failure" = true ]; then
        print_warning "Skipping persistent storage test due to critical failures in core functionality"
        print_warning "Fix Kerberos authentication and file operations before testing persistence"
    else
        if test_persistent_storage; then
            tests_passed=$((tests_passed + 1))
        else
            tests_failed=$((tests_failed + 1))
        fi
    fi

    # Cleanup
    cleanup_test_files

    # Final results
    print_header "Test Results Summary"
    echo "Tests passed: $tests_passed"
    echo "Tests failed: $tests_failed"
    echo "Total tests: $((tests_passed + tests_failed))"

    if [ $tests_failed -eq 0 ]; then
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
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "NFS Kerberos POC Test Suite"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --help, -h     Show this help message"
    echo "  --wait         Wait for pods to be ready before testing"
    echo ""
    echo "Test functions (can be run individually):"
    echo "  test_service_health        - Test KDC, NFS, and GSS services"
    echo "  test_pod_status           - Test Kubernetes pod status"
    echo "  test_kerberos_authentication - Test Kerberos ticket acquisition"
    echo "  test_nfs_mount_access     - Test NFS mount accessibility"
    echo "  test_file_operations      - Test file create/read/write operations"
    echo "  test_persistent_storage   - Test data persistence across pod restarts"
    echo "  cleanup_test_files        - Clean up test files"
    echo ""
    echo "Example: $0 test_nfs_mount_access"
    exit 0
fi

if [ "${1:-}" = "--wait" ]; then
    wait_for_pods
    shift
fi

# If a specific test function is provided, run only that
if [ $# -eq 1 ] && declare -f "$1" > /dev/null; then
    echo "Running specific test: $1"
    $1
else
    # Run all tests
    run_all_tests
fi
