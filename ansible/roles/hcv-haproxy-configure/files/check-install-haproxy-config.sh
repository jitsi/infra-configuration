#!/bin/bash
#
# check a draft haproxy config and install if it's valid

[ -z "$TEMPLATE_LOGDIR" ] && TEMPLATE_LOGDIR="/var/log/consul-template"
[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="$TEMPLATE_LOGDIR/haproxy-template.log"

if [ ! -d "$TEMPLATE_LOGDIR" ]; then
  mkdir $TEMPLATE_LOGDIR
fi

if [ ! -f "$TEMPLATE_LOGFILE" ]; then
  touch $TEMPLATE_LOGFILE
fi

function timestamp() {
  echo $(date --utc +%Y-%m-%d_%H:%M:%S.Z)
}

function log_msg() {
  echo "$(timestamp) [$$] hap-check-cfg: $1" | tee -a $TEMPLATE_LOGFILE
}

log_msg "starting check-install-haproxy-config.sh"

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
  log_msg "no DRAFT_CONFIG found, exiting..."
  exit 1
fi

# always emit at least a 0 to metrics
echo -n "jitsi.haproxy.reconfig:0|c" | nc -4u -w1 localhost 8125

if [ ! -f "$DRAFT_CONFIG" ]; then
    log_msg "draft haproxy config file $DRAFT_CONFIG does not exist"
    exit 1
fi

# validate the draft configuration
haproxy -c -f "$DRAFT_CONFIG" >/dev/null
if [ $? -gt 0 ]; then
    log_msg "new haproxy config failed to validate"
    echo -n "jitsi.haproxy.reconfig.failed:1|c" | nc -4u -w1 localhost 8125
    # log a copy of the new config
    cp "$DRAFT_CONFIG" $TEMPLATE_LOGDIR/$TIMESTAMP-haproxy.cfg.invalid
    exit 1
else
    log_msg "validated $DRAFT_CONFIG"
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
        log_msg "haproxy-configurator.sh forked"
        echo -n "jitsi.haproxy.configurator:1|c" | nc -4u -w1 localhost 8125
    else
        log_msg "haproxy_configurator.sh not started; there is already a fork running"
        echo -n "jitsi.haproxy.configurator:0|c" | nc -4u -w1 localhost 8125
    fi
else
    log_msg "in DRY_RUN mode"
fi
