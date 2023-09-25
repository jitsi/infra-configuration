#!/bin/bash

# haproxy-configurator fork

diff $DRAFT_CONFIG /etc/haproxy/haproxy.cfg
if [ $? -eq 0 ]; then
    echo "#### hc: $DRAFT_CONFIG; is identical to /etc/haproxy/haproxy.cfg, exiting configurator " >> $TEMPLATE_LOGFILE
    exit 0
fi

while true; do
    UNIX_TIME=$(date +%s)
    UNIX_TIME_OF_VALIDATED_CONFIG_FILE=$(stat -c %Y "${DRAFT_CONFIG}.validated")
    if [ $UNIX_TIME_OF_VALIDATED_CONFIG_FILE + 60 -gt $UNIX_TIME ]; then
        echo "#### hc: validated config file has been stable for 60 seconds, initiating locked reload" >> $TEMPLATE_LOGFILE
        consul lock -timeout=10m haproxy-configurator-payload.sh
        ## ** TODO check for timed out request
    else
        sleep 1
    fi
done

#delete local lock file
rm /tmp/haproxy-configurator-lock
