#!/bin/bash

[ -z "$CONFIG_BASE_PATH" ] && CONFIG_BASE_PATH="/etc/jitsi/jigasi"
[ -z "$SIP_COMMUNICATOR_PATH" ] && SIP_COMMUNICATOR_PATH="$CONFIG_BASE_PATH/sip-communicator.properties"
[ -z "$BASE_SIP_COMMUNICATOR_PATH" ] && BASE_SIP_COMMUNICATOR_PATH="$CONFIG_BASE_PATH/base-sip-communicator.properties"
[ -z "$XMPP_SIP_COMMUNICATOR_PATH" ] && XMPP_SIP_COMMUNICATOR_PATH="$CONFIG_BASE_PATH/xmpp-sip-communicator.properties"

[ -z "$TEMPLATE_LOGDIR" ] && TEMPLATE_LOGDIR="/var/log/jitsi/jigasi-shards"
[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="$TEMPLATE_LOGDIR/jigasi-reconfigure.log"

echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) starting configure-jigasi-wrapper.sh" >> $TEMPLATE_LOGFILE

cat $BASE_SIP_COMMUNICATOR_PATH $XMPP_SIP_COMMUNICATOR_PATH > $SIP_COMMUNICATOR_PATH

CONFIG_PATH="$SIP_COMMUNICATOR_PATH" /usr/share/jigasi/reconfigure_xmpp.sh >> $TEMPLATE_LOGFILE
RET=$?

if [ $RET -gt 0 ]; then
    echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) jigasi shards update failed" >> $TEMPLATE_LOGFILE
    echo -n "jitsi.config.jigasi.shards_update_update_failed:1|c" | nc -4u -w1 localhost 8125
    exit 1
else
    echo -n "jitsi.config.jigasi.shards_update_failed:0|c" | nc -4u -w1 localhost 8125
fi

echo -n "jitsi.config.jigasi.shards_update:1|c" | nc -4u -w1 localhost 8125

echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) jigasi shards reconfiguration complete" >> $TEMPLATE_LOGFILE

exit $RET
