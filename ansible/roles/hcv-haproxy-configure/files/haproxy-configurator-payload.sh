#!/bin/bash

# payload of the haproxy-configurator, assumed to be an operation protected by a consul lock

echo -n "jitsi.haproxy.reconfig_locked:1|c" | nc -4u -w1 localhost 8125

if [ -n "$1" ]; then
    TEMPLATE_LOGFILE=$1
else
    echo "## hc: missing TEMPLATE_LOGFILE, exiting"
    exit 1
fi

echo "#### hcp: entered haproxy-configurator-payload.sh" >> $TEMPLATE_LOGFILE

if [ -n "$2" ]; then
    DRAFT_CONFIG_VALIDATED=$2
else
    echo "## hc: missing DRAFT_CONFIG_VALIDATED, exiting" >> $TEMPLATE_LOGFILE
    FINAL_EXIT=1
fi

diff $DRAFT_CONFIG_VALIDATED /etc/haproxy/haproxy.cfg
if [ $? -eq 0 ]; then
    echo "#### hcp: the validated draft config is identical to the installed config; skipping" >> $TEMPLATE_LOGFILE
    exit 0
fi

# copy the validated config to the real config
cp $DRAFT_CONFIG_VALIDATED /etc/haproxy/haproxy.cfg

echo "#### hcp: draining load balancer" | tee -a $TEMPLATE_LOGFILE
/usr/local/bin/oci-lb-backend-drain.sh $TEMPLATE_LOGFILE
if [ $? -gt 0 ]; then
    echo "#### hcp: haproxy failed to drain from the load balancer" | tee -a $TEMPLATE_LOGFILE
    FINAL_EXIT=1
fi

if [[ "$FINAL_EXIT" -eq 0 ]]; then
    echo "#### hcp: reloading haproxy" >> $TEMPLATE_LOGFILE
    service haproxy reload
    if [[ $? -gt 0 ]]; then
        echo "#### hcp: haproxy failed to reload" | tee -a $TEMPLATE_LOGFILE
        echo -n "jitsi.haproxy.reconfig:0|c" | nc -4u -w1 localhost 8125
        FINAL_EXIT=1
    fi
    echo -n "jitsi.haproxy.reconfig:1|c" | nc -4u -w1 localhost 8125
fi

# undrain the haproxy from the load balancer
echo "#### hcp: undraining load balancer" | tee -a $TEMPLATE_LOGFILE
DRAIN_STATE="false" /usr/local/bin/oci-lb-backend-drain.sh $TEMPLATE_LOGFILE
if [[ $? -gt 0 ]] && [[ "$FINAL_EXIT" -eq 0 ]]; then
    echo "#### hcp: haproxy failed to undrain from the load balancer" | tee -a $TEMPLATE_LOGFILE
    FINAL_EXIT=1
fi

# log that a reconfigure happened
echo "#### hcp: succeeded to reload haproxy with new config" >> $TEMPLATE_LOGFILE

if [[ $FINAL_EXIT -gt 0 ]]; then
    echo -n "jitsi.haproxy.reconfig_failed:1|c" | nc -4u -w1 localhost 8125
    exit 1
else
    echo -n "jitsi.haproxy.reconfig_failed:0|c" | nc -4u -w1 localhost 8125
fi

exit $FINAL_EXIT