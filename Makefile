# Kubernetes NFS Kerberos POC Makefile
#
# This Makefile provides convenient targets for setting up, deploying,
# testing, and managing the NFS Kerberos POC environment across multiple machines.

.PHONY: all help install deploy test test-persistent test-renewal clean realclean status replace

all: help

# Install prerequisites for specific role on current machine
install:
	@echo "=== Installing Prerequisites ==="
	@if [ -z "$(ROLE)" ]; then \
		echo "ERROR: ROLE parameter is required"; \
		echo "Usage: make install KDC=<kdc_ip> NFS=<nfs_ip> K8S=<k8s_ip> ROLE=<role>"; \
		echo "Roles: kdc, nfs, k8s"; \
		echo "Examples:"; \
		echo "  make install KDC=192.168.1.10 NFS=192.168.1.11 K8S=192.168.1.12 ROLE=kdc"; \
		echo "  make install KDC=192.168.1.10 NFS=192.168.1.11 K8S=192.168.1.12 ROLE=nfs"; \
		echo "  make install KDC=192.168.1.10 NFS=192.168.1.11 K8S=192.168.1.12 ROLE=k8s"; \
		exit 1; \
	fi
	@if [ "$(ROLE)" = "kdc" ]; then \
		if [ -z "$(NFS)" ]; then \
			echo "ERROR: NFS IP required for KDC installation"; \
			echo "Usage: make install KDC=<kdc_ip> NFS=<nfs_ip> K8S=<k8s_ip> ROLE=kdc"; \
			exit 1; \
		fi; \
		echo "Installing KDC server..."; \
		sudo ./vm-scripts/install-kdc.sh "$(NFS)"; \
	elif [ "$(ROLE)" = "nfs" ]; then \
		if [ -z "$(KDC)" ] || [ -z "$(K8S)" ]; then \
			echo "ERROR: KDC and K8S IPs required for NFS installation"; \
			echo "Usage: make install KDC=<kdc_ip> NFS=<nfs_ip> K8S=<k8s_ip> ROLE=nfs"; \
			exit 1; \
		fi; \
		echo "Installing NFS server..."; \
		sudo ./vm-scripts/install-nfs.sh "$(KDC)" "$(K8S)"; \
	elif [ "$(ROLE)" = "k8s" ]; then \
		if [ -z "$(KDC)" ] || [ -z "$(NFS)" ]; then \
			echo "ERROR: KDC and NFS IPs required for Kubernetes installation"; \
			echo "Usage: make install KDC=<kdc_ip> NFS=<nfs_ip> K8S=<k8s_ip> ROLE=k8s"; \
			exit 1; \
		fi; \
		echo "Installing Kubernetes prerequisites..."; \
		sudo ./vm-scripts/install-k8s.sh "$(KDC)" "$(NFS)"; \
	else \
		echo "ERROR: Invalid ROLE '$(ROLE)'. Valid roles: kdc, nfs, k8s"; \
		exit 1; \
	fi
	@echo "✓ Installation complete for role: $(ROLE)"

# Default target - show available targets
help:
	@echo "Kubernetes NFS Kerberos POC - Available Targets:"
	@echo ""
	@echo "Setup:"
	@echo "  install    - Install prerequisites for specific role"
	@echo "               Usage: make install KDC=<kdc_ip> NFS=<nfs_ip> K8S=<k8s_ip> ROLE=<role>"
	@echo "               Roles: kdc, nfs, k8s"
	@echo "               Example: make install KDC=192.168.1.10 NFS=192.168.1.11 K8S=192.168.1.12 ROLE=kdc"
	@echo ""
	@echo "Deployment and testing:"
	@echo "  deploy     - Deploy Kubernetes cluster and NFS applications"
	@echo "               Usage: make deploy KDC=<kdc_ip> NFS=<nfs_ip>"
	@echo "  test       - Run comprehensive test suite to validate deployment"
	@echo "  test-persistent - Run persistent storage tests only"
	@echo "  test-renewal   - Run Kerberos renewal lifecycle test (~2 hours)"
	@echo "  status     - Show current status of all services and pods"
	@echo "  replace    - Force replace all client pods and clean credential caches"
	@echo "  clean      - Clean up Kubernetes resources only"
	@echo "  realclean  - Clean up everything (Kubernetes + NFS + Kerberos)"
	@echo ""

# Deploy Kubernetes cluster and applications
deploy:
	@echo "=== Deploying Kubernetes NFS Kerberos Applications ==="
	@if [ -z "$(KDC)" ] || [ -z "$(NFS)" ]; then \
		echo "ERROR: Both KDC and NFS IP addresses must be provided for multi-server deployment"; \
		echo "Usage: make deploy KDC=<kdc_ip> NFS=<nfs_ip>"; \
		echo "Example: make deploy KDC=192.168.1.10 NFS=192.168.1.11"; \
		exit 1; \
	else \
		echo "Multi-server deployment:"; \
		echo "Using KDC IP: $(KDC)"; \
		echo "Using NFS IP: $(NFS)"; \
		echo ""; \
		if ! command -v kubectl >/dev/null 2>&1; then \
			echo "ERROR: kubectl not found. Run prerequisites setup first."; \
			exit 1; \
		fi; \
		./deploy-k8s.sh "$(KDC)" "$(NFS)"; \
	fi
	@echo "✓ Deployment complete!"
	@echo ""
	@echo "Next: run 'make status' to validate the deployment and 'make test' to quick test pods"
	@echo ""

# Run comprehensive test suite
test:
	@echo "=== Running NFS Kerberos POC Test Suite ==="
	@if ! kubectl get pods >/dev/null 2>&1; then \
		echo "ERROR: Kubernetes cluster not accessible. Run 'make deploy' first."; \
		exit 1; \
	fi
	./test.sh
	@echo ""
	@echo "Test suite completed. Check results above."

# Run persistent storage tests only
test-persistent:
	@echo "=== Running Persistent Storage Tests ==="
	@if ! kubectl get pods >/dev/null 2>&1; then \
		echo "ERROR: Kubernetes cluster not accessible. Run 'make deploy' first."; \
		exit 1; \
	fi
	./test.sh persistent
	@echo ""
	@echo "Persistent storage test completed. Check results above."

# Run Kerberos renewal lifecycle test (~2 hours)
test-renewal:
	@echo "=== Running Kerberos Renewal Lifecycle Test ==="
	@echo "This test takes approximately 2 hours to complete"
	@if ! kubectl get pods >/dev/null 2>&1; then \
		echo "ERROR: Kubernetes cluster not accessible. Run 'make deploy' first."; \
		exit 1; \
	fi
	./test.sh renewal
	@echo ""
	@echo "Renewal lifecycle test completed. Check results above."

# Show current status of services and applications
status:
	@echo "=== NFS Kerberos POC Status ==="
	./status.sh

# Force replace all client pods
replace:
	@echo "=== Force Replacing All Client Pods ==="
	@if ! command -v kubectl >/dev/null 2>&1; then \
		echo "ERROR: kubectl not found. Ensure Kubernetes cluster is accessible."; \
		exit 1; \
	fi
	@echo "Cleaning up credential caches..."
	sudo rm -f /tmp/krb5cc_10002 /tmp/krb5cc_10003 /tmp/krb5cc_10004 /tmp/krb5cc_10005 /tmp/krb5cc_10006
	@echo "Replacing client manifests..."
	kubectl replace --force -f k8s-manifests/client-user10002.yaml -f k8s-manifests/client-user10003.yaml -f k8s-manifests/client-user10004.yaml -f k8s-manifests/client-user10005.yaml -f k8s-manifests/client-user10006.yaml
	@echo "✓ All client pods replaced successfully!"

# Clean up Kubernetes resources only
clean:
	@echo "=== Cleaning up Kubernetes resources ==="
	./cleanup-k8s.sh
	@echo "✓ Kubernetes cleanup complete!"

# Clean up everything (Kubernetes + NFS + Kerberos)
realclean:
	@echo "=== Complete System Cleanup ==="
	@echo "Removing all Kubernetes resources, NFS configuration, and Kerberos KDC..."
	@echo ""
	@echo "Step 1/2: Cleaning up Kubernetes..."
	./cleanup-k8s.sh || true
	@echo ""
	@echo "Step 2/2: Cleaning up NFS and Kerberos..."
	sudo ./vm-scripts/cleanup-nfs-kerberos.sh || true
	@echo ""
	@echo "✓ Complete cleanup finished!"
	@echo "System reset to initial state."
