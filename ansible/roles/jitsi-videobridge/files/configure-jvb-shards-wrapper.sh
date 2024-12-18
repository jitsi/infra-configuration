#!/bin/bash

[ -z "$TEMPLATE_LOGDIR" ] && TEMPLATE_LOGDIR="/var/log/jitsi/jvb-shards"
[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="$TEMPLATE_LOGDIR/jvb-reconfigure.log"

CONSUL_TEMPLATE_SHARDS_JSON="/etc/jitsi/videobridge/shards-candidate.json"
DRAFT_CONFIG_VALIDATED="/etc/jitsi/videobridge/shards-validated.json"

function timestamp() {
  echo $(date --utc +%Y-%m-%d_%H:%M:%S.Z)
}

function log_msg() {
  echo "$(timestamp) [$$] jvb-check-cfg: $1" | tee -a $TEMPLATE_LOGFILE
}

log_msg "starting configure-jvb-shards-wrapper.sh"

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

if [ ! -d "$TEMPLATE_LOGDIR" ]; then
  mkdir $TEMPLATE_LOGDIR
fi

if [ ! -f "$TEMPLATE_LOGFILE" ]; then
  touch $TEMPLATE_LOGFILE
fi

# always emit at least a 0 to metrics
echo -n "jitsi.config.jvb.reconfig:0|c" | nc -4u -w1 localhost 8125

CONFIG_TIMESTAMP=$(timestamp)

# validate the draft configuration
jq "$CONSUL_TEMPLATE_SHARDS_JSON" >/dev/null
if [ $? -gt 0 ]; then
    log_msg "new JVB shards json failed to validate"
    echo -n "jitsi.config.jvb.reconfig.failed:1|c" | nc -4u -w1 localhost 8125
    # log a copy of the new config
    cp "$CONSUL_TEMPLATE_SHARDS_JSON" $TEMPLATE_LOGDIR/$CONFIG_TIMESTAMP-shards.json.invalid
    exit 1
else
    cp $CONSUL_TEMPLATE_SHARDS_JSON $DRAFT_CONFIG_VALIDATED
    cp /etc/jitsi/videobridge/shards.json $TEMPLATE_LOGDIR/$CONFIG_TIMESTAMP-shards.json
    log_msg "validated $CONSUL_TEMPLATE_SHARDS_JSON"
    echo -n "jitsi.config.jvb.reconfig.failed:0|c" | nc -4u -w1 localhost 8125
fi

lock $PROGNAME

if [[ "$?" -eq 0 ]]; then
    /usr/local/bin/jvb-configurator.sh $TEMPLATE_LOGFILE $DRAFT_CONFIG_VALIDATED &
    log_msg "jvb-configurator.sh forked"
    echo -n "jitsi.config.jvb.configurator:1|c" | nc -4u -w1 localhost 8125
else
    log_msg "jvb-configurator.sh not started; there is already a fork running"
    echo -n "jitsi.config.jvb.configurator:0|c" | nc -4u -w1 localhost 8125
fi
