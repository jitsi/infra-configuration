#!/bin/bash

[ -z "$CONFIG_BASE_PATH" ] && CONFIG_BASE_PATH="/etc/jitsi/jigasi"
[ -z "$SIP_COMMUNICATOR_PATH" ] && SIP_COMMUNICATOR_PATH="$CONFIG_BASE_PATH/sip-communicator.properties"
[ -z "$BASE_SIP_COMMUNICATOR_PATH" ] && BASE_SIP_COMMUNICATOR_PATH="$CONFIG_BASE_PATH/base-sip-communicator.properties"
[ -z "$XMPP_SIP_COMMUNICATOR_PATH" ] && XMPP_SIP_COMMUNICATOR_PATH="$CONFIG_BASE_PATH/xmpp-sip-communicator.properties"

cat $BASE_SIP_COMMUNICATOR_PATH $XMPP_SIP_COMMUNICATOR_PATH > $SIP_COMMUNICATOR_PATH

CONFIG_PATH="$SIP_COMMUNICATOR_PATH" /usr/share/jigasi/reconfigure_xmpp.sh
exit $?
