# Kubernetes NFS Kerberos POC Makefile
#
# This Makefile provides convenient targets for setting up, deploying,
# testing, and managing the NFS Kerberos POC environment.

.PHONY: all help setup deploy test clean realclean status

all: help

# Default target - show available targets
help:
	@echo "Kubernetes NFS Kerberos POC - Available Targets:"
	@echo ""
	@echo "  setup      - Install and configure all prerequisites (KDC, NFS, K8s node)"
	@echo "  deploy     - Deploy Kubernetes cluster and NFS Kerberos applications"
	@echo "  test       - Run comprehensive test suite to validate deployment"
	@echo "  status     - Show current status of all services and pods"
	@echo "  clean      - Clean up Kubernetes resources only"
	@echo "  realclean  - Clean up everything (Kubernetes + NFS + Kerberos)"
	@echo ""

# Set up all prerequisites (KDC, NFS server, Kubernetes node)
setup:
	@echo "=== Setting up NFS Kerberos POC Prerequisites ==="
	@echo "Installing and configuring KDC, NFS server, and Kubernetes prerequisites..."
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
	@echo "Next: run 'make deploy' to deploy the applications"

# Deploy Kubernetes cluster and applications
deploy:
	@echo "=== Deploying Kubernetes NFS Kerberos Applications ==="
	@echo "This will:"
	@echo "  - Initialize Kubernetes cluster (if not already done)"
	@echo "  - Build and deploy NFS client containers"
	@echo "  - Deploy Kerberos sidecar containers"
	@echo "  - Set up persistent volumes and claims"
	@echo ""
	@if ! command -v kubectl >/dev/null 2>&1; then \
		echo "ERROR: kubectl not found. Run 'make setup' first."; \
		exit 1; \
	fi
	./deploy-k8s.sh
	@echo ""
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
