# Kubernetes NFS Kerberos POC Makefile
#
# This Makefile provides convenient targets for setting up, deploying,
# testing, and managing the NFS Kerberos POC environment across multiple machines.

.PHONY: all help single-node-setup deploy test clean realclean status

all: help

# Default target - show available targets
help:
	@echo "Kubernetes NFS Kerberos POC - Available Targets:"
	@echo ""
	@echo "Multi-machine setup:"
	@echo "  On KDC machine:     sudo ./vm-scripts/install-kdc.sh <nfs_ip>"
	@echo "  On NFS machine:     sudo ./vm-scripts/install-nfs.sh <kdc_ip> <k8s_ip>"
	@echo "  On K8s machine:     sudo ./vm-scripts/setup-k8s-node.sh <kdc_ip> <nfs_ip>"
	@echo ""
	@echo "Single-machine setup (legacy):"
	@echo "  single-node-setup  - Install and configure all prerequisites on one machine"
	@echo ""
	@echo "Deployment and testing:"
	@echo "  deploy     - Deploy Kubernetes cluster and NFS applications"
	@echo "               Single-node: make deploy (auto-detects local IP)"
	@echo "               Multi-node:  make deploy KDC=<kdc_ip> NFS=<nfs_ip>"
	@echo "  test       - Run comprehensive test suite to validate deployment"
	@echo "  status     - Show current status of all services and pods"
	@echo "  clean      - Clean up Kubernetes resources only"
	@echo "  realclean  - Clean up everything (Kubernetes + NFS + Kerberos)"
	@echo ""

# Set up all prerequisites (KDC, NFS server, Kubernetes node) - single machine
single-node-setup:
	@echo "=== Setting up NFS Kerberos POC Prerequisites (Single Machine) ==="
	@echo "Installing all components on current machine..."
	@echo ""
	@echo "Step 1/3: Installing Kerberos KDC..."
	sudo ./vm-scripts/install-kdc.sh
	@echo ""
	@echo "Step 2/3: Installing NFS server..."
	sudo ./vm-scripts/install-nfs.sh
	@echo ""
	@echo "Step 3/3: Setting up Kubernetes node prerequisites..."
	sudo ./vm-scripts/setup-k8s-node.sh
	@echo ""
	@echo "✓ Prerequisites setup complete!"

# Deploy Kubernetes cluster and applications
deploy:
	@echo "=== Deploying Kubernetes NFS Kerberos Applications ==="
	@if [ -z "$(KDC)" ] && [ -z "$(NFS)" ]; then \
		echo "No KDC/NFS IPs provided, using single-node setup..."; \
		if ! command -v kubectl >/dev/null 2>&1; then \
			echo "ERROR: kubectl not found. Run 'make single-node-setup' first."; \
			exit 1; \
		fi; \
		./deploy-k8s.sh; \
	elif [ -z "$(KDC)" ] || [ -z "$(NFS)" ]; then \
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
	@echo "Next: run 'make test' to validate the deployment"

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

# Show current status of services and applications
status:
	@echo "=== NFS Kerberos POC Status ==="
	./status.sh

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
