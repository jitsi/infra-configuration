#!/bin/bash

if [ -d "/opt/consul-template" ]; then
    echo "Consul template exists, skipping direct reconfiguration of JVB"
    exit 0
fi

#first rebuild the configuration files
CONFIGURE_ONLY=true ANSIBLE_TAGS="setup,jitsi-videobridge" /usr/local/bin/configure-jvb-local-oracle.sh

echo "JVB configuration signaling"
/usr/local/bin/configure-jvb-shards.sh
RET=$?
echo "JVB reconfiguration completed"
exit $RET