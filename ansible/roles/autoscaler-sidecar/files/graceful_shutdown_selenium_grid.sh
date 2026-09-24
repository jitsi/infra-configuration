#!/bin/bash

# Graceful shutdown for selenium-grid nodes running under nomad
# 1. Drain the Selenium Grid 4 node (stop accepting new sessions, wait for existing to finish)
# 2. Then perform the normal nomad graceful shutdown

SELENIUM_NODE_PORT=${SELENIUM_NODE_PORT:-5555}
SELENIUM_DRAIN_URL="http://localhost:${SELENIUM_NODE_PORT}/se/grid/node/drain"
SELENIUM_STATUS_URL="http://localhost:${SELENIUM_NODE_PORT}/status"
SELENIUM_DRAIN_TIMEOUT=${SELENIUM_DRAIN_TIMEOUT:-300}
SLEEP_TIME=10

echo "Starting selenium-grid graceful shutdown"

# Step 1: Issue drain command to the selenium grid node
echo "Sending drain request to Selenium Grid node at ${SELENIUM_DRAIN_URL}"
DRAIN_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${SELENIUM_DRAIN_URL}")

if [[ "$DRAIN_RESPONSE" == "200" ]]; then
    echo "Drain request accepted by Selenium Grid node"
else
    echo "Warning: Drain request returned HTTP ${DRAIN_RESPONSE}, continuing with shutdown"
fi

# Step 2: Wait for active sessions to complete
echo "Waiting for active sessions to drain (timeout: ${SELENIUM_DRAIN_TIMEOUT}s)"
ELAPSED=0
while [[ $ELAPSED -lt $SELENIUM_DRAIN_TIMEOUT ]]; do
    STATUS=$(curl -s "${SELENIUM_STATUS_URL}" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "Node status endpoint unreachable, assuming drained"
        break
    fi

    # Check if node has any active sessions
    ACTIVE_SESSIONS=$(echo "$STATUS" | jq -r '.value.node.slots // [] | map(select(.session != null)) | length' 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$ACTIVE_SESSIONS" ]]; then
        echo "Could not parse session count, assuming drained"
        break
    fi

    if [[ "$ACTIVE_SESSIONS" -eq 0 ]]; then
        echo "All sessions drained from Selenium Grid node"
        break
    fi

    echo "Still waiting for ${ACTIVE_SESSIONS} active session(s) to complete... (${ELAPSED}s/${SELENIUM_DRAIN_TIMEOUT}s)"
    sleep $SLEEP_TIME
    ELAPSED=$((ELAPSED + SLEEP_TIME))
done

if [[ $ELAPSED -ge $SELENIUM_DRAIN_TIMEOUT ]]; then
    echo "Selenium drain timeout reached after ${SELENIUM_DRAIN_TIMEOUT}s, proceeding with nomad shutdown"
fi

# Step 3: Proceed with normal nomad graceful shutdown
echo "Starting nomad graceful shutdown"
/usr/local/bin/nomad_graceful_shutdown.sh
exit $?
