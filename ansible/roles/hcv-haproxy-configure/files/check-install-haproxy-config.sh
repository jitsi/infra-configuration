#!/bin/bash
#
# check a draft haproxy config and install if it's valid

function logit() {
  echo "## $1"
  logger -p local0.notice -t ${0##*/}[$$] "$1"
}

logit "starting check-install-haproxy-config.sh"

if [ -n "$1" ]; then
    DRAFT_CONFIG=$1
fi

if [ -z "$DRAFT_CONFIG" ]; then
  logit "no DRAFT_CONFIG found, exiting..."
  exit 1
fi

if [ ! -f "$DRAFT_CONFIG" ]; then
    logit "draft haproxy config file $DRAFT_CONFIG does not exist"
    exit 1 
fi

haproxy -c -f "$DRAFT_CONFIG" >/dev/null
if [ $? -ne 0 ]; then
    logit "new haproxy config failed, exiting..."
    echo -n "jitsi.haproxy.reconfig_failed:1|c" | nc -4u -w1 localhost 8125
    exit 1
fi

logit "validated $DRAFT_CONFIG; copying to haproxy.cfg and restarting haproxy"

cp "$DRAFT_CONFIG" /etc/haproxy/haproxy.cfg
service haproxy reload

echo -n "jitsi.haproxy.reconfig:1|c" | nc -4u -w1 localhost 8125
