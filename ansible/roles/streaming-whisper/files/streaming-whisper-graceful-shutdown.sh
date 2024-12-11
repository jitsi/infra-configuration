#!/usr/bin/env bash

# Sets the server to drain mode and waits for all the connections to be closed before exiting
# with code 0 (clean shutdown). If the connections are not closed within the specified time,
# the script will exit with code 1 (dirty) and the autoscaler will shut down the instance anyway.

# It takes two parameters: WAIT_SECONDS and STATE_URL
# WAIT_SECONDS: Seconds to wait for the server to enter drain mode and close all connections.
#               Defaults to 100.
# STATE_URL:    The URL of the whisper state endpoint. Defaults to http://localhost:8003/state.

# Example usage: ./shutdown_script.sh 100 http://localhost:8003/state


WAIT_SECONDS=100
STATE_URL="http://localhost:8003/state"

[[ -z $1 ]] && echo "Parameter WAIT_SECONDS not set, using default $WAIT_SECONDS" || WAIT_SECONDS=$1
[[ -z $2 ]] && echo "Parameter STATE_URL not set, using default $STATE_URL" || STATE_URL=$2

echo "Waiting for $WAIT_SECONDS seconds for the server to enter drain mode and close all connections."

START_TIME=$(date +%s)

while true; do
  RESPONSE=$(curl -s $STATE_URL)
  WHISPER_STATE=$(echo $RESPONSE | jq -r '.state')
  ACTIVE_CONNECTIONS=$(echo $RESPONSE | jq -r '.connections')
  if [[ $WHISPER_STATE != "drain" ]]; then
    echo "Setting server in drain mode."
    curl -s -XPOST $STATE_URL -d '{"state": "drain"}' | jq -r '.request_status'
  else
    echo "Server is in drain mode. Waiting for $ACTIVE_CONNECTIONS connections to be closed before shutting down"
    if [[ $ACTIVE_CONNECTIONS -eq 0 ]]; then
      echo "All connections are closed. Shutting down the instance."
      exit 0
    fi
  fi
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
  if [[ $ELAPSED_TIME -gt $WAIT_SECONDS ]]; then
    break
  fi
  sleep 2
done

echo "Server did not close all connections within $WAIT_SECONDS seconds. Shutting down anyway."
exit 1
