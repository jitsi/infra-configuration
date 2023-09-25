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

echo "$TIMESTAMP starting check-install-haproxy-config.sh" >> $TEMPLATE_LOGFILE

if [ -n "$1" ]; then
    DRAFT_CONFIG=$1
fi

if [ -z "$DRAFT_CONFIG" ]; then
  echo "#### cihc: no DRAFT_CONFIG found, exiting..." >> $TEMPLATE_LOGFILE
  exit 1
fi

if [ ! -f "$DRAFT_CONFIG" ]; then
    echo "#### cihc: draft haproxy config file $DRAFT_CONFIG does not exist" >> $TEMPLATE_LOGFILE
    exit 1
fi

# always emit at least a 0 to metrics
echo -n "jitsi.haproxy.reconfig:0|c" | nc -4u -w1 localhost 8125

# validate the draft configuration
haproxy -c -f "$DRAFT_CONFIG" >/dev/null
if [ $? -gt 0 ]; then
    echo "#### cihc: new haproxy config failed to validate" >> $TEMPLATE_LOGFILE
    # TODO ** emit failed metric
    exit 1
else
    echo "#### cihc: validated $DRAFT_CONFIG" >> $TEMPLATE_LOGFILE
fi

if [ "$DRY_RUN" == "false" ]; then
    echo "#### chic: in DRY_RUN mode" >> $TEMPLATE_LOGFILE
fi

FINAL_EXIT=0
if [ "DRY_RUN" == "false" ]; then
    # log a copy of the new config
    cp "$DRAFT_CONFIG" $TEMPLATE_LOGDIR/$TIMESTAMP-haproxy.cfg
    # save new config as validated
    cp "$DRAFT_CONFIG" "${DRAFT_CONFIG}.validated"

        # if lock file does not exist
    if [ ! -f "/tmp/haproxy-configurator-lock" ]; then
        LOCK_FILE_NEW="true"
        touch /tmp/haproxy-configurator-lock
    fi

    if [ $? -gt 0 ]; then
        echo "#### chic: failed to copy the new haproxy config file to /etc/haproxy" >> $TEMPLATE_LOGFILE
        FINAL_EXIT=1
    elif [ "$LOCK_FILE_NEW" -eq "true" ]; then
        ./haproxy_configurator.sh &
        ## ** TODO capture FINAL_EXIT from here
        echo "####: chic: haproxy-configurator.sh started" >> $TEMPLATE_LOGFILE
        echo -n "jitsi.haproxy.configurator:1|c" | nc -4u -w1 localhost 8125
    else
        echo "####: chic: haproxy_configurator.sh not started; there is already a fork running" >> $TEMPLATE_LOGFILE
        echo -n "jitsi.haproxy.configurator:0|c" | nc -4u -w1 localhost 8125
    fi
fi
exit $FINAL_EXIT


            
            
            
            
            
            
            
            
