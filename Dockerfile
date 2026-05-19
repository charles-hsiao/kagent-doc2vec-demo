# syntax=docker/dockerfile:1

# ── Stage 1: rebuild better-sqlite3 for linux/arm64 ──────────────────────────
# The base image ships an x86_64 (amd64) better_sqlite3.node even in its arm64
# manifest, so we must compile a native arm64 copy inside the same Wolfi image.
FROM ghcr.io/kagent-dev/doc2vec/mcp:latest AS builder

USER root

# Install npm and the C/C++ toolchain needed by node-gyp
RUN apk add --no-cache npm build-base python3

# Rebuild better-sqlite3 for arm64 (the base image ships an x86_64 binary)
RUN cd /app && npm rebuild better-sqlite3

# Install the arm64 sqlite-vec native extension (only linux-x64 was bundled in the base image)
RUN cd /app && npm install --no-save sqlite-vec-linux-arm64@0.1.7-alpha.2

# ── Stage 2: final image ──────────────────────────────────────────────────────
FROM ghcr.io/kagent-dev/doc2vec/mcp:latest

# Configure the MCP server to scan all .db files under /data
ENV SQLITE_DB_DIR=/data
ENV TRANSPORT_TYPE=http
ENV PORT=3001

# Copy the freshly compiled arm64 native module from the builder stage
COPY --from=builder \
    /app/node_modules/better-sqlite3/build/Release/better_sqlite3.node \
    /app/node_modules/better-sqlite3/build/Release/better_sqlite3.node

# Copy the arm64 sqlite-vec native extension
COPY --from=builder \
    /app/node_modules/sqlite-vec-linux-arm64 \
    /app/node_modules/sqlite-vec-linux-arm64

# Create /data as root, then hand ownership to the app user
USER root
RUN mkdir -p /data && chown kagent:nodejs /data
USER kagent

# --chown sets ownership inline, avoiding a separate RUN chown layer
COPY --chown=kagent:nodejs ops-runbooks.db /data/ops-runbooks.db
COPY --chown=kagent:nodejs incident-postmortems.db /data/incident-postmortems.db

EXPOSE 3001
