#!/usr/bin/env bash

set -euo pipefail

# Project name
PROJECT_NAME="ai-quickstart-n8n"

# Log file
LOG_FILE="/var/log/${PROJECT_NAME}-setup.log"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "========================================="
log "Starting ${PROJECT_NAME} setup..."
log "========================================="

#==============================================================================
# Step 1: Check if required containers are running
#==============================================================================
log "Step 1: Checking required containers..."

REQUIRED_CONTAINERS="vllm embedding reranker pgvector"
CONTAINER_CHECK=$(docker ps --format '{{.Names}}')

for container in $REQUIRED_CONTAINERS; do
    if echo "$CONTAINER_CHECK" | grep -q "$container"; then
        log "✓ Container '$container' is running"
    else
        log "✗ ERROR: Container '$container' is not running"
        exit 1
    fi
done

log "✓ All required containers are running"

#==============================================================================
# Step 2: Wait for n8n to be healthy
#==============================================================================
log "Step 2: Waiting for n8n to be healthy..."

TIMEOUT=120
START_TIME=$(date +%s)

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))

    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5678/healthz || echo "000")

    if [ "$HTTP_CODE" = "200" ]; then
        log "✓ n8n is healthy (took ${ELAPSED}s)"
        break
    fi

    if [ $ELAPSED -ge $TIMEOUT ]; then
        log "✗ ERROR: Timeout waiting for n8n health check after ${TIMEOUT}s"
        exit 1
    fi

    sleep 2
done

#==============================================================================
# Step 3: Import n8n credentials and workflow
#==============================================================================
log "Step 3: Importing n8n credentials and workflow..."

CREDENTIALS_FILE="/opt/${PROJECT_NAME}/n8n_credentials.json"
WORKFLOW_FILE="/opt/${PROJECT_NAME}/n8n_workflow.json"

# Check credentials file
if [ -f "$CREDENTIALS_FILE" ]; then
    log "Importing credentials from ${CREDENTIALS_FILE}..."
    docker cp "$CREDENTIALS_FILE" n8n:/home/node/n8n_credentials.json
    docker exec n8n n8n import:credentials --input=/home/node/n8n_credentials.json
    log "✓ Credentials imported successfully"
else
    log "✗ ERROR: Credentials file not found: ${CREDENTIALS_FILE}"
    exit 1
fi

# Check workflow file
if [ -f "$WORKFLOW_FILE" ]; then
    log "Importing workflow from ${WORKFLOW_FILE}..."
    docker cp "$WORKFLOW_FILE" n8n:/home/node/n8n_workflow.json
    docker exec n8n n8n import:workflow --input=/home/node/n8n_workflow.json
    log "✓ Workflow imported successfully"
else
    log "✗ ERROR: Workflow file not found: ${WORKFLOW_FILE}"
    exit 1
fi

#==============================================================================
# Step 4: Install community node
#==============================================================================
log "Step 4: Installing n8n community node..."

docker exec n8n npm install n8n-nodes-universal-reranker
log "✓ Community node installed successfully"

#==============================================================================
# Step 5: Restart n8n and wait for health check
#==============================================================================
log "Step 5: Restarting n8n container..."

docker restart n8n

# Wait for container to start
sleep 10

log "Waiting for n8n to be healthy after restart..."
RESTART_START=$(date +%s)
RESTART_TIMEOUT=60

while true; do
    ELAPSED=$(($(date +%s) - RESTART_START))

    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5678/healthz || echo "000")

    if [ "$HTTP_CODE" = "200" ]; then
        log "✓ n8n restarted successfully (took ${ELAPSED}s)"
        break
    fi

    if [ $ELAPSED -ge $RESTART_TIMEOUT ]; then
        log "✗ ERROR: Timeout waiting for n8n restart after ${RESTART_TIMEOUT}s"
        exit 1
    fi

    sleep 2
done

#==============================================================================
# Step 6: Wait for vLLM to download gpt-oss model
#==============================================================================
log "Step 6: Waiting for vLLM to download gpt-oss model..."

VLLM_TIMEOUT=600
VLLM_START=$(date +%s)

while true; do
    ELAPSED=$(($(date +%s) - VLLM_START))

    if curl -s http://localhost:8000/v1/models | grep -q '"id":"openai/gpt-oss-20b"'; then
        log "✓ vLLM model loaded successfully (took ${ELAPSED}s)"
        break
    fi

    if [ $ELAPSED -ge $VLLM_TIMEOUT ]; then
        log "⚠ WARNING: Timeout waiting for vLLM model after ${VLLM_TIMEOUT}s. Model may still be downloading."
        break
    fi

    sleep 5
done

#==============================================================================
# Step 7: Done
#==============================================================================
log "========================================="
log "✓ Setup completed successfully!"
log "========================================="

exit 0
