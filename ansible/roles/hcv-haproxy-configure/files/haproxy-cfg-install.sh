#!/bin/bash

# add a 15 minute timeout to the whole thing?

SECONDS=0
RELOAD_SECONDS=60
TEST_CFG_MODIFY_TIME=$(stat -c %Y /tmp/haproxy.cfg.test)

while [ $SECONDS -lt $RELOAD_SECONDS ]; do
    # wait until the draft config file has been stable for a minute
    if [ TEST_CFG_MODIFY_TIME=$(stat -c %Y /tmp/haproxy.cfg.test) -gt TEST_CFG_MODIFY_TIME ]
        RELOAD_SECONDS=$(($SECONDS + 60))
    sleep 1
done

# validate the configuration 
haproxy -c -f "$DRAFT_CONFIG" >/dev/null
if [ $? -gt 0 ]; then
    echo "#### cihc: new haproxy config failed to validate" >> $TEMPLATE_LOGFILE
    exit 1
fi

## drain haproxy from oci lb
/usr/local/bin/oci-lb-backend-drain.sh

diff $DRAFT_CONFIG /etc/haproxy/haproxy.cfg
if [ $? -gt 0 ]; then
    echo "#### cihc: validated $DRAFT_CONFIG; copy to haproxy.cfg and reload haproxy" >> $TEMPLATE_LOGFILE

    # save a copy of the new config
    cp "$DRAFT_CONFIG" $TEMPLATE_LOGDIR/$TIMESTAMP-haproxy.cfg

    cp "$DRAFT_CONFIG" /etc/haproxy/haproxy.cfg
    if [ $? -gt 0 ]; then
        echo "#### chic: failed to copy the new haproxy config file to /etc/haproxy" >> $TEMPLATE_LOGFILE
        FINAL_EXIT=1
    else
        service haproxy reload
        if [ $? -gt 0 ]; then
            echo "#### chic: failed to reload haproxy service" >> $TEMPLATE_LOGFILE
            FINAL_EXIT=1
        fi
    fi

    echo -n "jitsi.haproxy.reconfig:1|c" | nc -4u -w1 localhost 8125
    echo "#### chic: succeeded to reload haproxy with new config" >> $TEMPLATE_LOGFILE
else 
    echo "#### cihc: validated $DRAFT_CONFIG; but new is the same as the old" >> $TEMPLATE_LOGFILE
fi

## undrain the haproxy from the load balancer
DRAIN=false /usr/local/bin/oci-lb-backend-drain.sh