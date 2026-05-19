# ──────────────────────────────────────────────────────────────
# Makefile — doc2vec Demo
# ──────────────────────────────────────────────────────────────

IMAGE        ?= ops-mcp-server
TAG          ?= latest
KIND_CLUSTER ?= kagent-doc2vec-demo
KUBE_CTX      = kind-$(KIND_CLUSTER)

-include .env
export

.PHONY: kind-setup kind-teardown build-vectors

build-vectors: ## Build doc2vec SQLite vector databases
	./build-vectors.sh

kind-setup: ## Create kind cluster, install kagent, build & deploy
	@test -f .env || (echo "Error: .env file not found — copy .env.example and fill in your keys"; exit 1)
	@test -n "$(OPENAI_API_KEY)" || (echo "Error: OPENAI_API_KEY is not set in .env"; exit 1)
	kind create cluster --name $(KIND_CLUSTER)
	kubectl config use-context $(KUBE_CTX)
	kubectl wait --for=condition=Ready nodes --all --timeout=120s --context $(KUBE_CTX)
	kagent install
	@echo "Waiting for kagent namespace to be created..."; \
	until kubectl get namespace kagent >/dev/null 2>&1; do sleep 3; done
	kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/kagent --timeout=120s
	kubectl create secret generic mcp-secrets \
		--from-literal=OPENAI_API_KEY=$(OPENAI_API_KEY) \
		--namespace=kagent --context=$(KUBE_CTX)
	docker build -t $(IMAGE):$(TAG) .
	kind load docker-image $(IMAGE):$(TAG) --name $(KIND_CLUSTER)
	kubectl apply -f k8s/ --context $(KUBE_CTX)

kind-teardown: ## Delete the kind cluster and remove generated .db files
	kind delete cluster --name $(KIND_CLUSTER)
