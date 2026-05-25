#!/bin/bash
set -e

# Default environment variables if not provided
GRAPH_NODE_URL=${GRAPH_NODE_URL:-"http://graph-node:8020/"}
IPFS_URL=${IPFS_URL:-"http://ipfs:5001"}
SUBGRAPH_NAME=${SUBGRAPH_NAME:-"coti-perps-analytics"}
VERSION_LABEL=${VERSION_LABEL:-"v0.0.1"}

# Wait for graph-node to be ready
echo "Waiting for graph-node at ${GRAPH_NODE_URL}..."
sleep 30

# Verify graph-cli installation
graph --version

# Pin the graft base manifest to IPFS so future grafted deploys can find it.
# Idempotent: re-pinning the same content returns the same hash.
EXPECTED_BASE_HASH="QmQFesWs3oHrtgN3ocpXk88arbwvFKYz9hAj1BcugRumTH"
if [ -f "./bootstrap-graft-base.yaml" ]; then
  echo "Pinning graft base manifest to IPFS at ${IPFS_URL}..."
  PIN_RESULT=$(curl -s -X POST -F "file=@bootstrap-graft-base.yaml" "${IPFS_URL}/api/v0/add?pin=true&cid-version=0&raw-leaves=false")
  echo "Pin result: $PIN_RESULT"
  if echo "$PIN_RESULT" | grep -q "$EXPECTED_BASE_HASH"; then
    echo "Graft base manifest pinned: $EXPECTED_BASE_HASH"
  else
    echo "WARNING: pinned hash does not match expected $EXPECTED_BASE_HASH"
  fi
fi

EXPECTED_BASE_085_HASH="QmTXZXrMhAgtonWxMNwPmzeHNzKs6DuTrnHm6SN4dUKR8e"
if [ -f "./bootstrap-graft-base-085-no-config.yaml" ]; then
  echo "Pinning 0.8.5 graft base manifest to IPFS at ${IPFS_URL}..."
  PIN_RESULT=$(curl -s -X POST -F "file=@bootstrap-graft-base-085-no-config.yaml" "${IPFS_URL}/api/v0/add?pin=true&cid-version=0&raw-leaves=false")
  echo "Pin result: $PIN_RESULT"
  if echo "$PIN_RESULT" | grep -q "$EXPECTED_BASE_085_HASH"; then
    echo "0.8.5 graft base manifest pinned: $EXPECTED_BASE_085_HASH"
  else
    echo "WARNING: pinned hash does not match expected $EXPECTED_BASE_085_HASH"
  fi
fi

# Create the subgraph namespace
echo "Creating subgraph namespace for ${SUBGRAPH_NAME}..."
graph create --node ${GRAPH_NODE_URL} ${SUBGRAPH_NAME} || true

# Deploy the pre-built subgraph
echo "Deploying subgraph ${SUBGRAPH_NAME} to ${GRAPH_NODE_URL} via IPFS at ${IPFS_URL}..."
graph deploy --node ${GRAPH_NODE_URL} --ipfs ${IPFS_URL} ${SUBGRAPH_NAME} --version-label ${VERSION_LABEL}

# Keep container running if needed for debugging
if [ "${KEEP_CONTAINER_ALIVE:-false}" = "true" ]; then
  echo "Deployment complete. Keeping container alive as requested..."
  tail -f /dev/null
else
  echo "Deployment complete for ${SUBGRAPH_NAME} version ${VERSION_LABEL}"
fi
