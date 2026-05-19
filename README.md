# kagent doc2vec Demo — Cloud-Native SRE Knowledge Base

A demo project showing how to use [doc2vec](https://github.com/kagent-dev/doc2vec) to vectorize internal SRE runbooks and incident post-mortems, then expose them to a [kagent](https://github.com/kagent-dev/kagent) AI agent via an MCP server — so on-call engineers can query operational knowledge in natural language.

## How It Works

```
runbooks/ + post-mortems/
        │
        ▼  npx doc2vec config.yaml
  ops-runbooks.db
  incident-postmortems.db
        │
        ▼  docker build + push
  MCP Server image (ghcr.io base + embedded .db files)
        │
        ▼  kubectl apply -f k8s/
  Kubernetes: Deployment + Service
             RemoteMCPServer (kagent CRD)
             Agent (ops-sre-agent)
        │
        ▼  kagent UI / API
  "How was the PostgreSQL connection exhaustion handled last time?"
```

## Project Structure

```
.
├── .env.example                         # Environment variable template
├── config.yaml                          # doc2vec source configuration
├── build-vectors.sh                     # Script: vectorize docs → .db files
├── Dockerfile                           # MCP server image with embedded .db files
├── runbooks/
│   ├── database/postgres-connection.md  # PostgreSQL connection troubleshooting
│   ├── kubernetes/pod-crashloopbackoff.md
│   └── oncall/onboarding-sre.md        # New on-call engineer guide
├── post-mortems/
│   ├── incident-2024-09-12-postgres-pool.md   # SEV-2: connection pool exhaustion
│   └── incident-2024-11-03-oom-kill.md        # SEV-1: OOMKilled cascade failure
└── k8s/
    ├── mcp-deployment.yaml   # Secret + ConfigMap + Deployment + Service
    ├── toolserver.yaml       # kagent RemoteMCPServer CRD
    └── agent.yaml            # kagent Agent CRD (ops-sre-agent)
```

## Prerequisites

- Node.js 18+
- OpenAI API key
- Docker (for building the MCP server image)
- A Kubernetes cluster with [kagent](https://kagent.dev/docs/kagent/introduction/installation) installed

## Quick Start

### Step 1 — Vectorize documents

```bash
cp .env.example .env
# Edit .env and set OPENAI_API_KEY=sk-...

./build-vectors.sh
# Produces: ops-runbooks.db, incident-postmortems.db
```

### Step 2 — Build and push the MCP server image

```bash
docker build -t <your-registry>/ops-mcp-server:latest .
docker push <your-registry>/ops-mcp-server:latest
```

> **Local development with kind?** See [Using a local kind cluster](#using-a-local-kind-cluster) below to skip the registry push.

### Step 3 — Deploy to Kubernetes

```bash
# Edit k8s/mcp-deployment.yaml:
#   - Replace <your_openai_api_key> in the Secret
#   - Replace <your-registry> in the Deployment image field

kubectl apply -f k8s/
```

### Step 4 — Query the agent

Open the kagent UI, find the `ops-sre-agent`, and ask questions such as:

- `PostgreSQL connection timeout alert — how did we handle it last time?`
- `What should a new on-call engineer read first?`
- `How do I troubleshoot a CrashLoopBackOff pod?`

## Using a local kind cluster

If you don't have a remote registry, you can run the entire stack locally with [kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker).

### Prerequisites

- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) — `brew install kind`
- [kubectl](https://kubernetes.io/docs/tasks/tools/) — `brew install kubectl`
- [kagent CLI](https://kagent.dev/docs/kagent/introduction/installation) — for installing kagent into the cluster

### Step A — Create a kind cluster

```bash
kind create cluster --name kagent-doc2vec-demo
# Verify the cluster is ready
kubectl cluster-info --context kind-kagent-doc2vec-demo
```

### Step B — Install kagent

```bash
# Follow the official kagent install guide, targeting your kind cluster
# https://kagent.dev/docs/kagent/introduction/installation
kagent install --context kind-kagent-doc2vec-demo
```

### Step C — Vectorize documents

```bash
cp .env.example .env
# Edit .env and set OPENAI_API_KEY=sk-...
./build-vectors.sh
```

### Step D — Build the image locally

```bash
# No registry needed — build with a local tag
docker build -t ops-mcp-server:local .
```

### Step E — Load the image into kind

```bash
# This makes the image available inside the kind cluster without a registry push
kind load docker-image ops-mcp-server:local --name kagent-doc2vec-demo
```

### Step F — Deploy to the kind cluster

```bash
# Patch the image reference to the local tag before applying
# In k8s/mcp-deployment.yaml set:
#   image: ops-mcp-server:local
#   imagePullPolicy: Never        ← prevents Kubernetes from trying to pull from a registry
#
# Also replace <your_openai_api_key> in the Secret field

kubectl apply -f k8s/ --context kind-kagent-doc2vec-demo
```

### Updating the image after changes

```bash
docker build -t ops-mcp-server:local .
kind load docker-image ops-mcp-server:local --name kagent-doc2vec-demo
kubectl rollout restart deployment/mcp-sqlite-vec -n kagent --context kind-kagent-doc2vec-demo
```

### Tearing down

```bash
kind delete cluster --name kagent-doc2vec-demo
```

---

## Adding Your Own Documents

1. Add `.md`, `.pdf`, or `.docx` files to `runbooks/` or `post-mortems/`
2. Re-run `./build-vectors.sh` to regenerate the vector databases
3. Rebuild and push the Docker image
4. Roll out the updated deployment: `kubectl rollout restart deployment/mcp-sqlite-vec -n kagent`

## Configuration Reference

| File | Purpose |
|------|---------|
| `config.yaml` | Defines doc2vec sources (paths, file types, output DB paths) |
| `.env` | `OPENAI_API_KEY` and optional embedding provider settings |
| `k8s/mcp-deployment.yaml` | Kubernetes resources for the MCP server |
| `k8s/toolserver.yaml` | Registers the MCP server as a kagent tool server |
| `k8s/agent.yaml` | Defines the SRE agent and its system prompt |

## Security Notes

- The Docker image runs as a non-root user (`kagent`) at runtime.
- `USER root` is used only during the image build to create `/data`; the final container user is `kagent`.
- The raw document content never leaves your environment — only embedding vectors are sent to the OpenAI API.
- For air-gapped or stricter environments, replace `EMBEDDING_PROVIDER=openai` with an Azure OpenAI or self-hosted endpoint.

## Related Links

- [doc2vec on GitHub](https://github.com/kagent-dev/doc2vec)
- [kagent documentation](https://kagent.dev/docs/kagent)
- [kagent Documentation Agent example](https://kagent.dev/docs/kagent/examples/documentation)
