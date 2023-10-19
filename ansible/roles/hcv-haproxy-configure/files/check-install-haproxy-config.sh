#!/bin/bash
#
# check a draft haproxy config and install if it's valid

[ -z "$TEMPLATE_LOGDIR" ] && TEMPLATE_LOGDIR="/tmp/ct-logs"
[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="$TEMPLATE_LOGDIR/template.log"

if [ ! -d "$TEMPLATE_LOGDIR" ]; then
  mkdir $TEMPLATE_LOGDIR
fi

if [ ! -f "$TEMPLATE_LOGFILE" ]; then
  touch $TEMPLATE_LOGFILE
fi

TIMESTAMP=$(date --utc +%Y-%m-%d_%H:%M:%S.Z)

echo "#### cihc: $TIMESTAMP starting check-install-haproxy-config.sh" >> $TEMPLATE_LOGFILE

readonly PROGNAME=$(basename "$0")
readonly LOCKFILE_DIR=/tmp
readonly LOCK_FD=200

function lock() {
    local prefix=$1
    local fd=${2:-$LOCK_FD}
    local lock_file=$LOCKFILE_DIR/$prefix.lock

    # create lock file
    eval "exec $fd>$lock_file"

    # acquier the lock
    flock -n $fd \
        && return 0 \
        || return 1
}

if [ -n "$1" ]; then
    DRAFT_CONFIG=$1
fi

if [ -n "$2" ]; then
    DRY_RUN=$2
fi

if [ -z "$DRAFT_CONFIG" ]; then
  echo "#### cihc: no DRAFT_CONFIG found, exiting..." >> $TEMPLATE_LOGFILE
  exit 1
fi

# always emit at least a 0 to metrics
echo -n "jitsi.haproxy.reconfig:0|c" | nc -4u -w1 localhost 8125

if [ ! -f "$DRAFT_CONFIG" ]; then
    echo "#### cihc: draft haproxy config file $DRAFT_CONFIG does not exist" >> $TEMPLATE_LOGFILE
    exit 1
fi

# validate the draft configuration
haproxy -c -f "$DRAFT_CONFIG" >/dev/null
if [ $? -gt 0 ]; then
    echo "#### cihc: new haproxy config failed to validate" >> $TEMPLATE_LOGFILE
    echo -n "jitsi.haproxy.reconfig.failed:1|c" | nc -4u -w1 localhost 8125
    exit 1
else
    echo "#### cihc: validated $DRAFT_CONFIG" >> $TEMPLATE_LOGFILE
    echo -n "jitsi.haproxy.reconfig.failed:0|c" | nc -4u -w1 localhost 8125
fi

if [ "$DRY_RUN" == "false" ]; then
    # log a copy of the new config
    cp "$DRAFT_CONFIG" $TEMPLATE_LOGDIR/$TIMESTAMP-haproxy.cfg
    # save new config as validated
    DRAFT_CONFIG_VALIDATED="${DRAFT_CONFIG}.validated"
    cp $DRAFT_CONFIG $DRAFT_CONFIG_VALIDATED

    lock $PROGNAME

    if [[ "$?" -eq 0 ]]; then
        /usr/local/bin/haproxy-configurator.sh $TEMPLATE_LOGFILE $DRAFT_CONFIG_VALIDATED &
        echo "#### chic: haproxy-configurator.sh forked" >> $TEMPLATE_LOGFILE
        echo -n "jitsi.haproxy.configurator:1|c" | nc -4u -w1 localhost 8125
    else
        echo "#### chic: haproxy_configurator.sh not started; there is already a fork running" >> $TEMPLATE_LOGFILE
        echo -n "jitsi.haproxy.configurator:0|c" | nc -4u -w1 localhost 8125
    fi
else
    echo "#### chic: in DRY_RUN mode" >> $TEMPLATE_LOGFILE
fi
