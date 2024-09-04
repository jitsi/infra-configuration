#!/bin/bash
# haproxy-configurator fork


if [ -n "$1" ]; then
    TEMPLATE_LOGFILE=$1
else
    echo "haproxy-configurator: missing TEMPLATE_LOGFILE, exiting"
    exit 1
fi

function timestamp() {
  echo $(date --utc +%Y-%m-%d_%H:%M:%S.Z)
}

function log_msg() {
  echo "$(timestamp) [$$] hap-cfg: $1" | tee -a $TEMPLATE_LOGFILE
}

log_msg "entered haproxy-configurator.sh"

FINAL_EXIT=0

if [ -n "$2" ]; then
    DRAFT_CONFIG_VALIDATED=$2
else
    log_msg "missing DRAFT_CONFIG_VALIDATED, exiting"
    FINAL_EXIT=1
fi

if [ ! -f "$DRAFT_CONFIG_VALIDATED" ] && [ "$FINAL_EXIT" == "0" ]; then
    log_msg "draft haproxy config file $DRAFT_CONFIG_VALIDATED does not exist, exiting"
    exit 1
fi

diff $DRAFT_CONFIG_VALIDATED /etc/haproxy/haproxy.cfg
if [ $? -eq 0 ]; then
    log_msg "$DRAFT_CONFIG_VALIDATED is identical to /etc/haproxy/haproxy.cfg, exiting configurator"
    exit 0
fi

if [ "$FINAL_EXIT" == "0" ]; then
    log_msg "waiting a minute for the validated configuration file to stabilize..."
    while true; do
        UNIX_TIME_OF_VALIDATED_CONFIG_FILE=$(stat -c %Y $DRAFT_CONFIG_VALIDATED)
        UNIX_TIME=$(date +%s)
        if (( $UNIX_TIME > $UNIX_TIME_OF_VALIDATED_CONFIG_FILE + 60 )); then
            log_msg "validated config file has been stable for 60 seconds, initiating reload"
            grep 'up true' /etc/haproxy/maps/up.map
            if [ $? -eq 0 ]; then
                consul lock -child-exit-code -timeout=10m haproxy_configurator_lock "/usr/local/bin/haproxy-configurator-payload.sh $TEMPLATE_LOGFILE $DRAFT_CONFIG_VALIDATED"
                if [ $? -eq 0 ]; then
                    log_msg "haproxy-configurator-payload.sh exited with zero"
                else
                    log_msg "haproxy-configurator-payload.sh exited with non-zero"
                    echo -n "jitsi.haproxy.reconfig_error:1|c" | nc -4u -w1 localhost 8125
                    FINAL_EXIT=1
                fi
                echo -n "jitsi.haproxy.reconfig_locked:0|c" | nc -4u -w1 localhost 8125
            else
                log_msg "haproxy is not up, skipping consul lock and immediately reloading"
                cp $DRAFT_CONFIG_VALIDATED /etc/haproxy/haproxy.cfg
                service haproxy reload
                if [[ $? -gt 0 ]]; then
                    log_msg "haproxy failed to reload when down"
                    FINAL_EXIT=1
                fi
            fi
            break
        else
            sleep 1
        fi
    done
fi

exit $FINAL_EXIT