#!/bin/bash
set -x
set -e

#first check if we have any input
[ -t 0 ] || IN=$(cat -)

if [ -z "$IN" ]; then
    echo "No input provided, exiting..."
    exit 1
fi

#now source or calculate our local values
. /usr/local/bin/aws_cache.sh

EVENT_ENVIRONMENT=$(echo $IN | jq -r '.environment')
EVENT_TYPE=$(echo $IN | jq -r '.event_type')
EVENT_EC2_INSTANCE_ID=$(echo $IN | jq -r '.ec2_instance_id')

if [ -z "$ENVIRONMENT" ]; then
    echo "No environment provided, exiting..."
    exit 2
fi

# if [ "$ENVIRONMENT" == "$EVENT_ENVIRONMENT" ]; then
#     #do the restart
#     if [ ! "$EVENT_EC2_INSTANCE_ID" == "$EC2_INSTANCE_ID" ]; then
#         /usr/local/bin/configure-haproxy.py
#     fi
#  fi
