#!/bin/bash
# haproxy-configurator fork


if [ -n "$1" ]; then
    TEMPLATE_LOGFILE=$1
else
    echo "## hc: missing TEMPLATE_LOGFILE, exiting"
    exit 1
fi

echo "#### hc: entered haproxy-configurator.sh" >> $TEMPLATE_LOGFILE

FINAL_EXIT=0

if [ -n "$2" ]; then
    DRAFT_CONFIG_VALIDATED=$2
else
    echo "## hc: missing DRAFT_CONFIG_VALIDATED, exiting" >> $TEMPLATE_LOGFILE
    FINAL_EXIT=1
fi

if [ ! -f "$DRAFT_CONFIG_VALIDATED" ] && [ "$FINAL_EXIT" == "0" ]; then
    echo "#### hc: draft haproxy config file $DRAFT_CONFIG_VALIDATED does not exist, exiting" >> $TEMPLATE_LOGFILE
    exit 1
fi

diff $DRAFT_CONFIG_VALIDATED /etc/haproxy/haproxy.cfg
if [ $? -eq 0 ]; then
    echo "#### hc: $DRAFT_CONFIG_VALIDATED is identical to /etc/haproxy/haproxy.cfg, exiting configurator " >> $TEMPLATE_LOGFILE
    rm /tmp/haproxy-configurator-lock
    exit 0
fi

if [ "$FINAL_EXIT" == "0" ]; then
    echo "#### hc: waiting a minute for the validated configuration file to stabilize..." >> $TEMPLATE_LOGFILE
    while true; do
        UNIX_TIME_OF_VALIDATED_CONFIG_FILE=$(stat -c %Y $DRAFT_CONFIG_VALIDATED)
        UNIX_TIME=$(date +%s)
        if (( $UNIX_TIME > $UNIX_TIME_OF_VALIDATED_CONFIG_FILE + 60 )); then
            echo "#### hc: validated config file has been stable for 60 seconds, initiating locked reload" >> $TEMPLATE_LOGFILE
            consul lock -child-exit-code -timeout=10m haproxy_configurator_lock "/usr/local/bin/haproxy-configurator-payload.sh $TEMPLATE_LOGFILE $DRAFT_CONFIG_VALIDATED"
            if [ $? -eq 0 ]; then
                echo "#### hc: haproxy-configurator-payload.sh exited with zero" >> $TEMPLATE_LOGFILE
            else
                echo "#### hc: haproxy-configurator-payload.sh exited with non-zero" >> $TEMPLATE_LOGFILE
                echo -n "jitsi.haproxy.reconfig_error:1|c" | nc -4u -w1 localhost 8125
                FINAL_EXIT=1
            fi
            echo -n "jitsi.haproxy.reconfig_locked:0|c" | nc -4u -w1 localhost 8125
            break
        else
            sleep 1
        fi
    done
fi

#delete local lock file
rm /tmp/haproxy-configurator-lock

exit $FINAL_EXIT