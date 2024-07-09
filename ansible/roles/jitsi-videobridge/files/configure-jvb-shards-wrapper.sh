#!/bin/bash

[ -z "$SHARDS_LOGDIR" ] && SHARDS_LOGDIR="/var/log/jitsi/jvb-shards"
[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="$TEMPLATE_LOGDIR/haproxy-template.log"

if [ ! -d "$TEMPLATE_LOGDIR" ]; then
  mkdir $TEMPLATE_LOGDIR
fi

if [ ! -f "$TEMPLATE_LOGFILE" ]; then
  touch $TEMPLATE_LOGFILE
fi

cp /etc/jitsi/videobridge/shards.json /var/log/jitsi/jvb-shards/$(date --utc +%Y-%m-%d_%H:%M:%S.Z)-shards.json

echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) starting configure-jvb-shards.sh" >> $TEMPLATE_LOGFILE
/usr/local/bin/configure-jvb-shards.sh
RET=$?

if [ $? -gt 0 ]; then
    echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) jvb shards update failed" >> $TEMPLATE_LOGFILE
    echo -n "jitsi.jvb.shards_update_update_failed:1|c" | nc -4u -w1 localhost 8125
    exit 1
else
    echo -n "jitsi.jvb.shards_update_failed:0|c" | nc -4u -w1 localhost 8125
fi

echo -n "jitsi.jvb.shards_update:1|c" | nc -4u -w1 localhost 8125

echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) jvb shards reconfiguration complete" >> $TEMPLATE_LOGFILE

exit $RET