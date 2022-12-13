#!/bin/bash

#first check if we have any input
[ -t 0 ] || IN=$(cat -)

if [ -z "$IN" ]; then
    echo "No input provided, exiting..."
    exit 1
fi
(
#now source or calculate our local values
. /usr/local/bin/aws_cache.sh

EVENT_ENVIRONMENT=$(echo $IN | jq -r '.environment')
[[ "$EVENT_ENVIRONMENT" == "null" ]] && EVENT_ENVIRONMENT=""

EVENT_TYPE=$(echo $IN | jq -r '.event_type')
[[ "$EVENT_TYPE" == "null" ]] && EVENT_TYPE=""

EVENT_RELEASE_NUMBER=$(echo $IN | jq -r '.release_number')
[[ "$EVENT_RELEASE_NUMBER" == "null" ]] && EVENT_RELEASE_NUMBER=""

if [ -z "$ENVIRONMENT" ]; then
    echo "No local environment found, exiting..."
    exit 2
fi

if [ -z "$RELEASE_NUMBER" ]; then
    echo "No local release number found, exiting..."
    exit 2
fi

if [ -z "$EVENT_TYPE" ]; then
    echo "No event type provided, exiting..."
    exit 2
fi

if [ -z "$EVENT_ENVIRONMENT" ]; then
    echo "No EVENT_ENVIRONMENT provided, exiting..."
    exit 2
fi

if [ -z "$EVENT_RELEASE_NUMBER" ]; then
    echo "No EVENT_RELEASE_NUMBER provided, exiting..."
    exit 2
fi

#only run reconfiguration on new shards
if [ "$EVENT_TYPE" == "RELEASE_DEPLOY" ]; then
    echo "Received RELEASE_DEPLOY event"
    echo "$IN"
    #only run if our local environment is "all" or else matches the new shard
    if [ "${ENVIRONMENT}" = "all" ] || [ "$ENVIRONMENT" == "$EVENT_ENVIRONMENT" ]; then
        echo "Matched evironment $EVENT_ENVIRONMENT"
        if [ "$RELEASE_NUMBER" == "$EVENT_RELEASE_NUMBER" ]; then
        echo "Matched release number $RELEASE_NUMBER"
          #do the restart
          /usr/local/bin/reconfigure-jvb.sh
        fi
    fi
fi
) >> /var/log/local/reconfigure-jvb.log