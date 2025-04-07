#!/bin/bash

[ -z "$CONFIG_BASE_PATH" ] && CONFIG_BASE_PATH="/etc/jitsi/jigasi"

[ -z "$CANDIDATE_PATH" ] && CANDIDATE_PATH="$CONFIG_BASE_PATH/xmpp-sip-communicator-candidate.properties"
[ -z "$VALIDATED_PATH" ] && VALIDATED_PATH="$CONFIG_BASE_PATH/xmpp-sip-communicator-validated.properties"

[ -z "$TEMPLATE_LOGDIR" ] && TEMPLATE_LOGDIR="/var/log/jitsi/jigasi-shards"

[ -d "$TEMPLATE_LOGDIR" ] || mkdir -p $TEMPLATE_LOGDIR
[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="$TEMPLATE_LOGDIR/jigasi-reconfigure.log"


function timestamp() {
  echo $(date --utc +%Y-%m-%d_%H:%M:%S.Z)
}

function log_msg() {
  echo "$(timestamp) [$$] jigasi-check-cfg: $1" | tee -a $TEMPLATE_LOGFILE
}

if [ ! -d "$TEMPLATE_LOGDIR" ]; then
  mkdir $TEMPLATE_LOGDIR
fi

if [ ! -f "$TEMPLATE_LOGFILE" ]; then
  touch $TEMPLATE_LOGFILE
fi

readonly PROGNAME=$(basename "$0")
readonly LOCKFILE_DIR=/tmp
readonly LOCK_FD=200

function lock() {
    local prefix=$1
    local fd=${2:-$LOCK_FD}
    local lock_file=$LOCKFILE_DIR/$prefix.lock

    # create lock file
    eval "exec $fd>$lock_file"

    # aquire the lock
    flock -n $fd \
        && return 0 \
        || return 1
}

log_msg "starting configure-jigasi-wrapper.sh"

# always emit at least a 0 to metrics
echo -n "jitsi.config.jigasi.reconfig:0|c" | nc -4u -w1 localhost 8125

CONFIG_TIMESTAMP=$(timestamp)

cp "$CANDIDATE_PATH" "$TEMPLATE_LOGDIR/xmmp-sip-communicator.properties.$CONFIG_TIMESTAMP"

# TODO: actually validate the draft configuration, for now just check if it is a valid file
grep -q '^[[:space:]]*#' "$CANDIDATE_PATH" >/dev/null
if [ $? -gt 0 ]; then
    log_msg "new jigasi config failed to validate"
    echo -n "jitsi.config.jigasi.reconfig.failed:1|c" | nc -4u -w1 localhost 8125
    exit 1
else
    cp $CANDIDATE_PATH $VALIDATED_PATH
    echo -n "jitsi.config.jigasi.reconfig.failed:0|c" | nc -4u -w1 localhost 8125
fi

lock $PROGNAME

if [[ "$?" -eq 0 ]]; then
    /usr/local/bin/jigasi-configurator.sh $TEMPLATE_LOGFILE $VALIDATED_PATH &
    log_msg "jigasi-configurator.sh forked"
    echo -n "jitsi.config.jigasi.configurator:1|c" | nc -4u -w1 localhost 8125
else
    log_msg "jvb-configurator.sh not started; there is already a fork running"
    echo -n "jitsi.config.jigasi.configurator:0|c" | nc -4u -w1 localhost 8125
fi
