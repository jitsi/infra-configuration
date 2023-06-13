#!/bin/bash

# 1. The script issues drain commands to all running batch jobs
# 2. The script waits for all nomad jobs to be in a "dead" state
# 3. The script returns

# sleep this long between checking allocation status
SLEEP_TIME=10
# delay shutdown AT MOST 6 hours = 21600 seconds
TERMINATION_DELAY_TIMEOUT=21600


# set node eligibility to ineligible
nomad node eligibility -self -disable

# drain the node
nomad node drain -self -enable -detach -yes -deadline 6h

# determine local ID
NODE_ID="$(nomad node status -self -t '{{ .ID }}')"

# determine all running allocations
RUNNING_ALLOCS="$(curl --request GET "localhost:4646/v1/allocations?task_states=false&filter=NodeID%3D%3D%22${NODE_ID}%22%20and%20ClientStatus%3D%3D%22running%22")"

BATCH_ALLOCS="$(echo $RUNNING_ALLOCS | jq '.|map(select(.JobType=="batch"))')"

ALLOC_COUNT="$(echo "${BATCH_ALLOCS}" | jq '. | length')"
if [[ $ALLOC_COUNT -gt 0 ]]; then
    echo "Found $ALLOC_COUNT running batch allocations. Issuing drain commands...";
    for i in $(seq 0 $((ALLOC_COUNT-1))); do
        DRAIN_COMMAND=
        TASK_TYPE="$(echo "${BATCH_ALLOCS}" | jq -r ".[$i].TaskGroup")"
        ALLOC_ID="$(echo "${BATCH_ALLOCS}" | jq -r ".[$i].ID")"
        if [[ "$TASK_TYPE" == "jibri" ]]; then
            DRAIN_COMMAND="/opt/jitsi/jibri/graceful_shutdown.sh"
        fi
        if [[ "$TASK_TYPE" == "jicofo" ]]; then
            DRAIN_COMMAND="/opt/jitsi/jicofo/graceful_shutdown.sh"
        fi
        if [[ "$TASK_TYPE" == "jvb" ]]; then
            DRAIN_COMMAND="/opt/jitsi/jvb/graceful_shutdown.sh"
        fi
        echo "Issuing drain command $DRAIN_COMMAND for allocation $ALLOC_ID";
        nomad alloc exec -task "$TASK_TYPE" "$ALLOC_ID" "$DRAIN_COMMAND"
    done
fi

# now wait for all allocations to be dead
echo "Waiting for all allocations to be dead..."
SLEEP_COUNT=0
while true; do
    RUNNING_ALLOCS="$(curl --request GET "localhost:4646/v1/allocations?task_states=false&filter=NodeID%3D%3D%22${NODE_ID}%22%20and%20ClientStatus%3D%3D%22running%22")"
    BATCH_ALLOCS="$(echo $RUNNING_ALLOCS | jq '.|map(select(.JobType=="batch"))')"
    ALLOC_COUNT="$(echo "${BATCH_ALLOCS}" | jq '. | length')"
    if [[ $ALLOC_COUNT -eq 0 ]]; then
        echo "All batch allocations are dead."
        break
    fi
    echo "Still waiting for $ALLOC_COUNT allocations to be dead..."
    if [[ $SLEEP_COUNT -ge $TERMINATION_DELAY_TIMEOUT ]]; then
        echo "Timed out waiting for allocations to be dead."
        exit 1
    fi
    SLEEP_COUNT=$(( $SLEEP_COUNT + $SLEEP_TIME ))

    sleep $SLEEP_TIME
done
