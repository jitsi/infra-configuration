#!/bin/bash
#
# check a draft haproxy config and install if it's valid, draining the load balancer while the action is in progress

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

FINAL_EXIT=0
UPDATED_CFG=0

haproxy -c -f "$DRAFT_CONFIG" >/dev/null
if [ $? -gt 0 ]; then
    echo "#### cihc: new haproxy config failed to validate" >> $TEMPLATE_LOGFILE
    FINAL_EXIT=1
fi

if [ -z "$ACTUALLY_RUN" ]; then
  echo "#### cihc: ACTUALLY_RUN not set, exiting..." >> $TEMPLATE_LOGFILE
  exit 1
fi

if [ $FINAL_EXIT -eq 0 ]; then
    diff $DRAFT_CONFIG /etc/haproxy/haproxy.cfg
    if [ $? -gt 0 ]; then
        echo "#### cihc: validated $DRAFT_CONFIG; copy to haproxy.cfg and reload haproxy" >> $TEMPLATE_LOGFILE

        /usr/local/bin/oci-lb-backend-drain.sh
        if [ $? -gt 0 ]; then
            echo "#### cihc: haproxy failed to drain from the load balancer" >> $TEMPLATE_LOGFILE
            FINAL_EXIT=1
            break
        fi

        # save a copy of the new config
        cp "$DRAFT_CONFIG" $TEMPLATE_LOGDIR/$TIMESTAMP-haproxy.cfg

        cp "$DRAFT_CONFIG" /etc/haproxy/haproxy.cfg
        if [ $? -gt 0 ]; then
            echo "#### chic: failed to copy the new haproxy config file to /etc/haproxy" >> $TEMPLATE_LOGFILE
            FINAL_EXIT=1
            break
        else
            service haproxy reload
            if [ $? -gt 0 ]; then
                echo "#### chic: failed to reload haproxy service" >> $TEMPLATE_LOGFILE
                FINAL_EXIT=1
                break
            fi
            UPDATED_CFG=1
        fi

        echo -n "jitsi.haproxy.reconfig:1|c" | nc -4u -w1 localhost 8125
        echo "#### chic: succeeded to reload haproxy with new config" >> $TEMPLATE_LOGFILE
    else 
        echo "#### cihc: validated $DRAFT_CONFIG; but new is the same as the old" >> $TEMPLATE_LOGFILE
        UPDATED_CFG=0
    fi
fi

## undrain the haproxy from the load balancer
if [ $FINAL_EXIT -eq 0 ] && [ $UPDATED_CFG -eq 1 ]; then

    ## give the haproxy a moment to contemplate its existence
    sleep 15
    
    ## undrain the haproxy from the load balancer
    DRAIN=false /usr/local/bin/oci-lb-backend-drain.sh
    if [ $? -gt 0 ]; then
        echo "#### cihc: haproxy failed to undrain from the load balancer" >> $TEMPLATE_LOGFILE
        FINAL_EXIT=1
    fi
fi

if [ $FINAL_EXIT -gt 0 ]; then
    echo -n "jitsi.haproxy.reconfig_failed:1|c" | nc -4u -w1 localhost 8125
    exit 1
else
    echo -n "jitsi.haproxy.reconfig_failed:0|c" | nc -4u -w1 localhost 8125
fi
