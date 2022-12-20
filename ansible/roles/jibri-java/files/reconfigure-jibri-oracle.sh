#!/bin/bash

LOGPATH="/var/log/jitsi/reconfigure-jibri.log"
#first rebuild the configuration files
echo "Reconfiguring jibri, check logs in $LOGPATH"
CONFIGURE_ONLY=true ANSIBLE_TAGS="setup,jibri" /usr/local/bin/configure-jibri-local.sh >> $LOGPATH 2>&1
if [ $? -eq 0 ]; then
    echo "Jibri reconfiguration successful"
    echo "Running service jibri reload"
    #now gracefully reload jibri
    service jibri reload >> $LOGPATH
    echo "Jibri reload completed"
    exit 0
else
    echo "Jibri reload failed, check logs in $LOGPATH"
fi