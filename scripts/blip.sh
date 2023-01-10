#!/bin/sh

# This script can be used to emulate the kind of network blips that we've been
# experiencing since our recent move to Oracle (mid/late 2020). A basic usage
# example that will disrupt two bridges is:
#
# ENVIRONMENT=meet-jit-si
# REGION=us-west-2
# SHARD=shard
# ./blip.sh --duration=60 --bridge-ips=ip1,ip2,...
#
# Note that this script relies on the successful invocation of node.py in order
# to fetch the bridge IPs, so make sure you run it in an appropriate
# virtualenv.

if [ -n "$DEBUG" ]; then
  set -x
fi

# emulate an xmpp timeout by blocking the xmpp connection of instance $1
# for 30 seconds
disrupt_xmpp() (
  IP=$1
  XMPP_CLIENT_PORT=`$BLIP_SSH $IP sudo grep PORT /etc/jitsi/videobridge/jvb.conf | cut -d= -f2`
  if [ -z $XMPP_CLIENT_PORT ]; then
    echo "WARN disruption failed (unable to discover the XMPP port)" >&2
  else
    $BLIP_SSH $IP sudo iptables -A INPUT -p tcp --sport $XMPP_CLIENT_PORT -j DROP
    sleep $BLIP_DURATION
    $BLIP_SSH $IP sudo iptables -D INPUT -p tcp --sport $XMPP_CLIENT_PORT -j DROP
  fi
)

# emulate a bridge failure by taking down the bridge process of instance $1
disrupt_process() (
  IP=$1
  $BLIP_SSH $IP systemctl stop jitsi-videobridge2
  sleep $BLIP_DURATION
  $BLIP_SSH $IP systemctl start jitsi-videobridge2
)

jvb_ips() {
  if [ -n "$BLIP_BRIDGE_IPS" ]; then
    # run in non-batch mode and grep for the ips that are specified in the
    # command line. Typically we have public ips in the command line. These are
    # converted into internal ips)
    REGEX="(`echo $BLIP_BRIDGE_IPS | sed 's/,/|/g'`)"
    "$(dirname $0)"/node.py --role JVB --environment $ENVIRONMENT --shard $SHARD --oracle | grep -E "$REGEX" | cut -d'|' -f4
  else
    "$(dirname $0)"/node.py --role JVB --environment $ENVIRONMENT --shard $SHARD --oracle --batch
  fi
}

# 10 bridges going down at different points of time during 1min and jicofo
# trying to move participants
blip() {
  for IP in `jvb_ips`; do
    disrupt_xmpp $IP &
  done
  wait
}
usage() {
  echo "Usage: $0 --duration=seconds [--bridge-ips=IP1[,IP2,...]] [--debug]" >&2
  exit 1
}

for arg in "$@"; do
  optname=`echo $arg | cut -d= -f1`
  optvalue=`echo $arg | cut -d= -f2`
  case $optname in
    --duration) BLIP_DURATION=$optvalue;;
    --bridge-ips) BLIP_BRIDGE_IPS=$optvalue;;
    --debug) set -x;;
    *) usage ;;
  esac
done

if [ -z "$BLIP_DURATION" -o -z "$SHARD" ]; then
  usage
fi

if [ -z "$BLIP_SSH" ]; then
  BLIP_SSH=ssh
fi

blip
