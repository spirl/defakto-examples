
.PHONY: env-up env-down env-reset help

CLUSTER_NAME := istio-nonstandard-id
USE_CTLPTL := $(shell command -v ctlptl 2> /dev/null)

# help: Show available commands
help:
	@echo "Available commands:"
	@echo "  make env-up     - Start the demo environment"
	@echo "  make env-down   - Stop the demo environment"
	@echo "  make env-reset  - Reset the demo environment"
	@echo ""
	@echo "Tools detected:"
ifdef USE_CTLPTL
	@echo "  ✓ ctlptl found - will use ctlptl for cluster management"
else
	@echo "  ✗ ctlptl not found - will use kind directly"
endif

# env-up: Start the demo environment
env-up:
	@echo "Installing tool versions (mise)..."
	@mise install
	@echo "Starting demo environment..."
ifdef USE_CTLPTL
	@echo "Using ctlptl to create cluster with registry"
	@ctlptl apply -f ctlptl-cluster-config.yaml
else
	@echo "Using kind directly (no ctlptl)"
	@kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)" || kind create cluster --name $(CLUSTER_NAME)
endif
	@echo "Starting Tilt..."
	@mise exec -- tilt up

# env-down: Stop the demo environment
env-down:
	@echo "Stopping demo environment..."
	@kubectl config use-context kind-$(CLUSTER_NAME) 2>/dev/null || true
	@tilt down || echo "Tilt may not be running"
	@echo "Deleting cluster..."
ifdef USE_CTLPTL
	@ctlptl delete -f ctlptl-cluster-config.yaml
else
	@kind delete cluster --name $(CLUSTER_NAME)
endif
	@echo "Cleanup complete"

# env-reset: Reset demo environment
env-reset: env-down env-up
