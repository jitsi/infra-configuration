#!/bin/bash

if [ -n "$1" ]; then
    LOGFILE=$1
else
    echo "## hc: missing LOGFILE, exiting"
    exit 1
fi

TIMESTAMP=$(date --utc +%Y-%m-%d_%H:%M:%S.Z)

echo "#### cpm: $TIMESTAMP starting check-peer-mesh.sh" >> $LOGFILE

# check to make sure the haproxy has at least 1 remote peer

REMOTE_PEER_DATA=$(echo "show peers" | sudo -u haproxy socat stdio /var/run/haproxy/admin.sock | grep haproxy | grep remote)
REMOTE_PEER_COUNT=$(echo "$REMOTE_PEER_DATA" | wc | awk -F" " '{print $1}')

if [ "$REMOTE_PEER_COUNT" -eq 0 ]; then
    echo "#### cpm: haproxy has no remote peers" >> $LOGFILE
    exit 1
fi

# check to make sure that all haproxy peers have established connections

REMOTE_PEER_ESTABLISHED_COUNT=$(echo "$REMOTE_PEER_DATA" | grep ESTA | wc | awk -F" " '{print $1}')

if [ "$REMOTE_PEER_ESTABLISHED_COUNT" -ne "$REMOTE_PEER_COUNT" ]; then
    echo "#### cpm: haproxy has $REMOTE_PEER_COUNT peers but only $REMOTE_PEER_ESTABLISHED_COUNT are established" >> $LOGFILE
    exit 1
fi

