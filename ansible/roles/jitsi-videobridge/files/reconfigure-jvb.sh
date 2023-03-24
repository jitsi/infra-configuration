#!/bin/bash

if [ -d "/opt/consul-template" ]; then
    echo "Consul template exists, skipping direct reconfiguration of JVB"
    exit 0
fi

#first rebuild the configuration files
CONFIGURE_ONLY=true ANSIBLE_TAGS="setup,jitsi-videobridge" /usr/local/bin/configure-jvb-local.sh

echo "JVB configuration signaling"
#now gracefully reload jibri
/usr/local/bin/configure-jvb-shards.sh
RET=$?
echo "JVB reload completed"
exit $RET