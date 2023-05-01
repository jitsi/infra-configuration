#!/bin/bash
#
# check a draft haproxy config and install if it's valid

[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="/tmp/template.log"

if [ ! -f "$TEMPLATE_LOGFILE" ]; then
  touch $TEMPLATE_LOGFILE
fi

echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) starting check-install-haproxy-config.sh" >> $TEMPLATE_LOGFILE

if [ -n "$1" ]; then
    DRAFT_CONFIG=$1
fi

if [ -z "$DRAFT_CONFIG" ]; then
  echo "#### cihc: no DRAFT_CONFIG found, exiting..." >> $TEMPLATE_LOGFILE
  exit 1
fi

if [ ! -f "$DRAFT_CONFIG" ]; then
    echo "#### cihc: draft haproxy config file $DRAFT_CONFIG does not exist" >> $TEMPLATE_LOGFILE
    exit 1
fi

haproxy -c -f "$DRAFT_CONFIG" >/dev/null
if [ $? -gt 0 ]; then
    echo "#### cihc: new haproxy config failed, exiting..." >> $TEMPLATE_LOGFILE
    echo -n "jitsi.haproxy.reconfig_failed:1|c" | nc -4u -w1 localhost 8125
    exit 1
else
    echo -n "jitsi.haproxy.reconfig_failed:0|c" | nc -4u -w1 localhost 8125
fi

echo "$(date --utc +%Y%m%d_%H%M%SZ) cihc: validated $DRAFT_CONFIG; copying to haproxy.cfg and restarting haproxy" >> $TEMPLATE_LOGFILE

cp "$DRAFT_CONFIG" /etc/haproxy/haproxy.cfg
service haproxy reload

echo -n "jitsi.haproxy.reconfig:1|c" | nc -4u -w1 localhost 8125
