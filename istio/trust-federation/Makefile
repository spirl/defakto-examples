
.PHONY: env-up env-down env-reset help

CLUSTER_NAME := istio-trust-federation
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
	@echo "Starting demo environment..."
ifdef USE_CTLPTL
	@echo "Using ctlptl to create cluster with registry"
	@ctlptl apply -f cluster.yaml
else
	@echo "Using kind directly (no ctlptl)"
	@kind create cluster --name $(CLUSTER_NAME) || echo "Cluster may already exist"
endif
	@echo "Starting Tilt..."
	@tilt up

# env-down: Stop the demo environment
env-down:
	@echo "Stopping demo environment..."
	@kubectl config use-context kind-$(CLUSTER_NAME) 2>/dev/null || true
	@tilt down || echo "Tilt may not be running"
	@echo "Deleting cluster..."
ifdef USE_CTLPTL
	@ctlptl delete -f cluster.yaml
else
	@kind delete cluster --name $(CLUSTER_NAME)
endif
	@echo "Cleanup complete"

# env-reset: Reset demo environment
env-reset: env-down env-up
