#!/bin/bash

if [ -n "$1" ]; then
    LOGFILE=$1
else
    echo "check-peer-mesh: missing LOGFILE, exiting"
    exit 1
fi

function timestamp() {
  echo $(date --utc +%Y-%m-%d_%H:%M:%S.Z)
}

function log_msg() {
  echo "$(timestamp) [$$] hap-checkpeers: $1" | tee -a $LOGFILE
}

log_msg "starting check-peer-mesh.sh"

# check to make sure the haproxy has at least 1 remote peer
REMOTE_PEER_DATA=$(echo "show peers" | sudo -u haproxy socat stdio /var/run/haproxy/admin.sock | grep haproxy | grep remote)

if [ "$?" -ne 0 ]; then
    log_msg "haproxy has no remote peers"
    exit 1
fi

# check to make sure that all haproxy peers have established connections
REMOTE_PEER_COUNT=$(echo "$REMOTE_PEER_DATA" | wc | awk -F" " '{print $1}')
REMOTE_PEER_ESTABLISHED_COUNT=$(echo "$REMOTE_PEER_DATA" | grep ESTA | wc | awk -F" " '{print $1}')

if [ "$REMOTE_PEER_ESTABLISHED_COUNT" -ne "$REMOTE_PEER_COUNT" ]; then
    log_msg "haproxy has $REMOTE_PEER_COUNT peers but only $REMOTE_PEER_ESTABLISHED_COUNT are established"
    exit 1
fi

log_msg "check-peer-mesh.sh succeeded with all $REMOTE_PEER_COUNT remote peer connections established"
