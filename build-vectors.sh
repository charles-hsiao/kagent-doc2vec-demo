#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# build-vectors.sh
# Vectorize runbooks/ and post-mortems/ using doc2vec,
# generating ops-runbooks.db and incident-postmortems.db
# ──────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── 1. Load .env ─────────────────────────────
if [[ -f .env ]]; then
  info "Loading .env"
  set -o allexport
  # shellcheck disable=SC1091
  source .env
  set +o allexport
else
  warn ".env not found, falling back to existing environment variables"
fi

# ── 2. Prerequisites check ───────────────────
info "Checking prerequisites..."

# Node.js >= 18
if ! command -v node &>/dev/null; then
  error "node not found. Install Node.js 18+: https://nodejs.org"
fi
NODE_VERSION=$(node -e "process.stdout.write(process.versions.node.split('.')[0])")
if [[ "$NODE_VERSION" -lt 18 ]]; then
  error "Node.js >= 18 required, current: v$(node -v)"
fi
info "Node.js $(node -v) ✓"

# OPENAI_API_KEY
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  error "OPENAI_API_KEY is not set. Copy .env.example to .env and fill in your API key."
fi
info "OPENAI_API_KEY is set ✓"

# config.yaml
if [[ ! -f config.yaml ]]; then
  error "config.yaml not found"
fi

# Source directories
for dir in runbooks post-mortems; do
  if [[ ! -d "$dir" ]]; then
    error "Source directory not found: $dir"
  fi
  FILE_COUNT=$(find "$dir" -type f \( -name "*.md" -o -name "*.pdf" -o -name "*.docx" \) | wc -l | tr -d ' ')
  info "Source $dir: ${FILE_COUNT} file(s) found ✓"
done

# ── 3. Run doc2vec ────────────────────────────
info "Vectorizing documents (npx doc2vec)..."
echo ""

if ! npx --yes doc2vec config.yaml; then
  error "doc2vec failed, see output above"
fi

echo ""

# ── 4. Verify output ──────────────────────────
info "Verifying output files..."

ALL_OK=true
for db in ops-runbooks.db incident-postmortems.db; do
  if [[ -f "$db" ]]; then
    SIZE=$(du -sh "$db" | cut -f1)
    info "${db} (${SIZE}) ✓"
  else
    warn "${db} not found, check db_path in config.yaml"
    ALL_OK=false
  fi
done

if [[ "$ALL_OK" == false ]]; then
  error "Some vector databases were not generated, check doc2vec output above"
fi