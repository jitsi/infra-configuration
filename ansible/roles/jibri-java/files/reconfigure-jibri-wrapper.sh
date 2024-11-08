#!/bin/bash

function timestamp() {
  date --utc +%Y-%m-%d_%H:%M:%S.Z
}

function log_msg() {
  echo "$(timestamp) [$$] jibri-wrapper: $1" | tee -a $TEMPLATE_LOGFILE
}

[ -z "$TEMPLATE_LOGDIR" ] && TEMPLATE_LOGDIR="/var/log/jitsi/jibri-shards"

[ -d "$TEMPLATE_LOGDIR" ] || mkdir -p $TEMPLATE_LOGDIR
[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="$TEMPLATE_LOGDIR/jibri-reconfigure.log"
[ -z "$XMPP_CONF_FILE" ] && XMPP_CONF_FILE="/etc/jitsi/jibri/xmpp.conf"

log_msg "starting"
cp $XMPP_CONF_FILE $TEMPLATE_LOGDIR/xmpp.conf.$(date --utc +%Y-%m-%d_%H:%M:%S.Z)

/usr/sbin/service jibri reload
RET=$?

if [ $RET -gt 0 ]; then
    log_msg "update failed"
    echo -n "jitsi.config.jibri.shards_update_update_failed:1|c" | nc -4u -w1 localhost 8125
else
    log_msg "update successful"
    echo -n "jitsi.config.jibri.shards_update_failed:0|c" | nc -4u -w1 localhost 8125
fi

echo -n "jitsi.config.jibri.shards_update:1|c" | nc -4u -w1 localhost 8125

log_msg "sleep 10 after reload"
sleep 10

log_msg "complete"


exit $RET
