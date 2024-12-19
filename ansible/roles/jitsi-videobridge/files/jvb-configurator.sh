#!/bin/bash
# jvb-configurator fork

if [ -n "$1" ]; then
    TEMPLATE_LOGFILE=$1
else
    echo "jvb-configurator: missing TEMPLATE_LOGFILE, exiting"
    exit 1
fi

CONSUL_TEMPLATE_SHARDS_JSON="/etc/jitsi/videobridge/shards-candidate.json"
LIVE_SHARD_JSON="/etc/jitsi/videobridge/shards.json"

function timestamp() {
  echo $(date --utc +%Y-%m-%d_%H:%M:%S.Z)
}

function log_msg() {
  echo "$(timestamp) [$$] jvb-cfg: $1" | tee -a $TEMPLATE_LOGFILE
}

log_msg "entered jvb-configurator.sh"

FINAL_EXIT=0

if [ -n "$2" ]; then
    DRAFT_CONFIG_VALIDATED=$2
else
    log_msg "missing DRAFT_CONFIG_VALIDATED, exiting"
    FINAL_EXIT=1
fi

if [ ! -f "$DRAFT_CONFIG_VALIDATED" ] && [ "$FINAL_EXIT" == "0" ]; then
    log_msg "draft jvb shards file $DRAFT_CONFIG_VALIDATED does not exist, exiting"
    exit 1
fi

if [ "$FINAL_EXIT" == "0" ]; then
    log_msg "waiting 10 seconds for the validated configuration file to stabilize..."
    while true; do
        UNIX_TIME_OF_VALIDATED_CONFIG_FILE=$(stat -c %Y $DRAFT_CONFIG_VALIDATED)
        UNIX_TIME=$(date +%s)
        if (( $UNIX_TIME > $UNIX_TIME_OF_VALIDATED_CONFIG_FILE + 10 )); then
            log_msg "validated shards json file has been stable for 10 seconds, initiating processing"
            diff $DRAFT_CONFIG_VALIDATED $LIVE_SHARD_JSON
            if [ $? -eq 0 ]; then
                log_msg "$DRAFT_CONFIG_VALIDATED is identical to $LIVE_SHARD_JSON, exiting configurator"
                break;
            fi

            cp $DRAFT_CONFIG_VALIDATED $LIVE_SHARD_JSON
            /usr/local/bin/configure-jvb-shards.sh | tee -a $TEMPLATE_LOGFILE
            RET=$?

            if [ $RET -gt 0 ]; then
                echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) jvb shards update failed" >> $TEMPLATE_LOGFILE
                echo -n "jitsi.config.jvb.shards_update_update_failed:1|c" | nc -4u -w1 localhost 8125
                exit 1
            else
                echo -n "jitsi.config.jvb.shards_update_failed:0|c" | nc -4u -w1 localhost 8125
            fi
            # copy the live config over test config and kick off consul-template to make sure there are not any new changes
            diff $LIVE_SHARD_JSON $CONSUL_TEMPLATE_SHARDS_JSON
            if [ $? -ne 0 ]; then
                log_msg "live config is different than test config; reloading consul-template"
                cp $LIVE_SHARD_JSON $CONSUL_TEMPLATE_SHARDS_JSON
                service consul-template reload
                if [[ $? -gt 0 ]]; then
                    log_msg "consul-template failed to reload"
                    FINAL_EXIT=1
                fi
            fi
            break
        else
            sleep 1
        fi
    done
fi

echo -n "jitsi.config.jvb.shards_update:1|c" | nc -4u -w1 localhost 8125
echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) jvb shards reconfiguration complete" >> $TEMPLATE_LOGFILE

exit $FINAL_EXIT
