#!/usr/bin/env bash

set -euo pipefail

# Get project name from script's parent directory
PROJECT_NAME="$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")"

# Log file
LOG_FILE="/var/log/${PROJECT_NAME}-setup.log"

# ANSI color codes
readonly YELLOW='\033[1;33m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

# Logging function
log() {
    echo -e "${GREEN}$1${NC}" | tee -a "$LOG_FILE"
}

# Check if setup was already completed
if [ -f "$LOG_FILE" ] && grep -q "Setup completed successfully!" "$LOG_FILE"; then
    echo "Setup already completed. Exiting to avoid duplicate execution."
    echo "If you need to re-run setup, remove the log file: $LOG_FILE"
    exit 0
fi

log "Continue ${PROJECT_NAME} setup..."

#==============================================================================
# Step 1: Check if required containers are running
#==============================================================================
log "Checking required containers..."

for container in vllm embedding reranker pgvector; do
    docker ps --format '{{.Names}}' | grep -q "$container" || { log "ERROR: Container '$container' is not running"; exit 1; }
    log "Container '$container' is running"
done

log "All required containers are running"

#==============================================================================
# Step 2: Wait for n8n to be healthy
#==============================================================================
log "Waiting for n8n to be healthy..."

START_TIME=$(date +%s)
N8N_READY=false
while [ $(($(date +%s) - START_TIME)) -lt 120 ]; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5678/healthz || echo 000)" = "200" ] && { N8N_READY=true; log "n8n is healthy (took $(($(date +%s) - START_TIME))s)"; break; }
    sleep 2
done
[ "$N8N_READY" = true ] || { log "ERROR: Timeout waiting for n8n health check"; exit 1; }

#==============================================================================
# Step 3: Import n8n credentials and workflow & restart n8n
#==============================================================================
log "Importing n8n credentials and workflow..."

CREDENTIALS_FILE="/opt/${PROJECT_NAME}/n8n_credentials.json"
WORKFLOW_FILE="/opt/${PROJECT_NAME}/n8n_workflow.json"

[ -f "$CREDENTIALS_FILE" ] || { log "ERROR: Credentials file not found: ${CREDENTIALS_FILE}"; exit 1; }
log "Importing n8n credentials..."
docker cp "$CREDENTIALS_FILE" n8n:/home/node/n8n_credentials.json
docker exec n8n n8n import:credentials --input=/home/node/n8n_credentials.json
log "Credentials imported"

[ -f "$WORKFLOW_FILE" ] || { log "ERROR: Workflow file not found: ${WORKFLOW_FILE}"; exit 1; }
log "Importing n8n workflow..."
docker cp "$WORKFLOW_FILE" n8n:/home/node/n8n_workflow.json
docker exec n8n n8n import:workflow --input=/home/node/n8n_workflow.json
log "Workflow imported"

# Install Universal Reranker node
log "Installing n8n-nodes-universal-reranker node..."
docker exec n8n npm install n8n-nodes-universal-reranker

log "Restarting n8n container..."
docker restart n8n

log "Waiting for n8n to be healthy after restart..."
RESTART_START=$(date +%s)
N8N_RESTARTED=false
while [ $(($(date +%s) - RESTART_START)) -lt 60 ]; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5678/healthz || echo 000)" = "200" ] && { N8N_RESTARTED=true; log "n8n restarted successfully (took $(($(date +%s) - RESTART_START))s)"; break; }
    sleep 2
done
[ "$N8N_RESTARTED" = true ] || { log "ERROR: Timeout waiting for n8n restart"; exit 1; }

#==============================================================================
# Step 6: Wait for vLLM to download gpt-oss model
#==============================================================================
log "Waiting for vLLM to download gpt-oss model..."

VLLM_START=$(date +%s)
while [ $(($(date +%s) - VLLM_START)) -lt 600 ]; do
    curl -s http://localhost:8000/v1/models | grep -q '"id":"openai/gpt-oss-20b"' && { log "vLLM model loaded (took $(($(date +%s) - VLLM_START))s)"; break; }
    sleep 5
done

log "DONE !!"

exit 0
