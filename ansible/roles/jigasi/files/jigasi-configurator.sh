#!/bin/bash
# jvb-configurator fork
[ -z "$CONFIG_BASE_PATH" ] && CONFIG_BASE_PATH="/etc/jitsi/jigasi"
[ -z "$SIP_COMMUNICATOR_PATH" ] && SIP_COMMUNICATOR_PATH="$CONFIG_BASE_PATH/sip-communicator.properties"
[ -z "$BASE_SIP_COMMUNICATOR_PATH" ] && BASE_SIP_COMMUNICATOR_PATH="$CONFIG_BASE_PATH/base-sip-communicator.properties"
[ -z "$XMPP_SIP_COMMUNICATOR_PATH" ] && XMPP_SIP_COMMUNICATOR_PATH="$CONFIG_BASE_PATH/xmpp-sip-communicator.properties"
[ -z "$CONSUL_TEMPLATE_CANDIDATE_PATH" ] && CONSUL_TEMPLATE_CANDIDATE_PATH="$CONFIG_BASE_PATH/xmpp-sip-communicator-candidate.properties"

if [ -n "$1" ]; then
    TEMPLATE_LOGFILE=$1
else
    echo "jigasi-configurator: missing TEMPLATE_LOGFILE, exiting"
    exit 1
fi

function timestamp() {
  echo $(date --utc +%Y-%m-%d_%H:%M:%S.Z)
}

function log_msg() {
  echo "$(timestamp) [$$] jigasi-cfg: $1" | tee -a $TEMPLATE_LOGFILE
}

log_msg "entered jigasi-configurator.sh"

FINAL_EXIT=0

if [ -n "$2" ]; then
    DRAFT_CONFIG_VALIDATED=$2
else
    log_msg "missing DRAFT_CONFIG_VALIDATED, exiting"
    FINAL_EXIT=1
fi

if [ ! -f "$DRAFT_CONFIG_VALIDATED" ] && [ "$FINAL_EXIT" == "0" ]; then
    log_msg "draft jigasi xmpp communicator file $DRAFT_CONFIG_VALIDATED does not exist, exiting"
    exit 1
fi

if [ "$FINAL_EXIT" == "0" ]; then
    log_msg "waiting 10 seconds for the validated configuration file to stabilize..."
    while true; do
        UNIX_TIME_OF_VALIDATED_CONFIG_FILE=$(stat -c %Y $DRAFT_CONFIG_VALIDATED)
        UNIX_TIME=$(date +%s)
        if (( $UNIX_TIME > $UNIX_TIME_OF_VALIDATED_CONFIG_FILE + 10 )); then
            log_msg "validated xmpp properties file has been stable for 10 seconds, initiating processing"
            diff $DRAFT_CONFIG_VALIDATED $XMPP_SIP_COMMUNICATOR_PATH
            if [ $? -eq 0 ]; then
                log_msg "$DRAFT_CONFIG_VALIDATED is identical to $XMPP_SIP_COMMUNICATOR_PATH, exiting configurator"
                break;
            fi

            # place draft config into place
            cp $DRAFT_CONFIG_VALIDATED $XMPP_SIP_COMMUNICATOR_PATH
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
            # copy the live config over test config and kick off consul-template to make sure there are not any new changes
            diff $XMPP_SIP_COMMUNICATOR_PATH $CONSUL_TEMPLATE_CANDIDATE_PATH
            if [ $? -ne 0 ]; then
                log_msg "live config is different than test config; reloading consul-template"
                cp $XMPP_SIP_COMMUNICATOR_PATH $CONSUL_TEMPLATE_CANDIDATE_PATH
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


echo -n "jitsi.config.jigasi.shards_update:1|c" | nc -4u -w1 localhost 8125
log_msg "jigasi shards reconfiguration complete"

exit $FINAL_EXIT
