#!/bin/bash

# payload of the haproxy-configurator, assumed to be an operation protected by a consul lock

echo -n "jitsi.haproxy.reconfig_locked:1|c" | nc -4u -w1 localhost 8125

diff $DRAFT_CONFIG /etc/haproxy/haproxy.cfg
if [ $? -gt 0 ];
    echo "####: hcp: validated draft config is identical to the installed config; skipping"
    exit 0
fi

# copy the validated config to the real config
cp ${DRAFT_CONFIG}.validated /etc/haproxy/haproxy.cfg

/usr/local/bin/oci-lb-backend-drain.sh
if [ $? -gt 0 ]; then
    echo "#### hcp: haproxy failed to drain from the load balancer" | tee -a $TEMPLATE_LOGFILE
    exit 1
fi

# reload haproxy
service haproxy reload

# undrain the haproxy from the load balancer
DRAIN_STATE="false" /usr/local/bin/oci-lb-backend-drain.sh
if [ $? -gt 0 ]; then
    echo "#### hcp: haproxy failed to undrain from the load balancer" | tee -a $TEMPLATE_LOGFILE
    FINAL_EXIT=1
fi

# emit success metric and log
echo -n "jitsi.haproxy.reconfig:1|c" | nc -4u -w1 localhost 8125
echo "#### hcp: succeeded to reload haproxy with new config" >> $TEMPLATE_LOGFILE
fi

# install the haproxy config
FINAL_EXIT=/usr/local/bin/haproxy-cfg-install.sh

# clean config directory
find $TEMPLATE_LOGDIR -type f -mtime +14 -name '*.cfg' -execdir rm -- '{}' \;

if [ $FINAL_EXIT -gt 0 ]; then
    echo -n "jitsi.haproxy.reconfig_failed:1|c" | nc -4u -w1 localhost 8125
    exit 1
else
    echo -n "jitsi.haproxy.reconfig_failed:0|c" | nc -4u -w1 localhost 8125
fi

