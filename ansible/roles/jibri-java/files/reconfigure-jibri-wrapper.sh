#!/bin/bash

[ -z "$TEMPLATE_LOGDIR" ] && TEMPLATE_LOGDIR="/var/log/jitsi/jibri-shards"

[ -d "$TEMPLATE_LOGDIR" ] || mkdir -p $TEMPLATE_LOGDIR
[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="$TEMPLATE_LOGDIR/jibri-reconfigure.log"
[ -z "$XMPP_CONF_FILE" ] && XMPP_CONF_FILE="/etc/jitsi/jibri/xmpp.conf"

echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) starting reconfigure-jibri-wrapper.sh" >> $TEMPLATE_LOGFILE
cp $XMPP_CONF_FILE $TEMPLATE_LOGDIR/xmpp.conf.$(date --utc +%Y-%m-%d_%H:%M:%S.Z)

/usr/sbin/service jibri reload
RET=$?

if [ $RET -gt 0 ]; then
    echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) jibri shards update failed" >> $TEMPLATE_LOGFILE
    echo -n "jitsi.config.jibri.shards_update_update_failed:1|c" | nc -4u -w1 localhost 8125
else
    echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) jibri shards update successful" >> $TEMPLATE_LOGFILE
    echo -n "jitsi.config.jibri.shards_update_failed:0|c" | nc -4u -w1 localhost 8125
fi

echo -n "jitsi.config.jibri.shards_update:1|c" | nc -4u -w1 localhost 8125

echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) jibri shards reconfiguration sleep 10 after reload" >> $TEMPLATE_LOGFILE
sleep 10

echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) jibri shards reconfiguration complete" >> $TEMPLATE_LOGFILE


exit $RET
