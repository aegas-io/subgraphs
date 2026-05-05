#!/bin/bash
set -e

# Default environment variables if not provided
GRAPH_NODE_URL=${GRAPH_NODE_URL:-"http://graph-node:8020/"}
IPFS_URL=${IPFS_URL:-"http://ipfs:5001"}
SUBGRAPH_NAME=${SUBGRAPH_NAME:-"coti-perps-analytics"}
VERSION_LABEL=${VERSION_LABEL:-"v0.0.2"}

# Wait for graph-node to be ready
echo "Waiting for graph-node at ${GRAPH_NODE_URL}..."
sleep 30

# Verify graph-cli installation
graph --version

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
