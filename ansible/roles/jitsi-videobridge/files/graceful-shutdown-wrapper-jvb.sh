#!/bin/bash
echo "Dump pre-terminate stats for JVB"
# this script is run from different users, e.g. jsidecar, ubuntu, root, and should not use sudo commands
PRE_TERMINATE_STATS="/usr/local/bin/dump-pre-terminate-stats-jvb.sh"
if [ -x "$PRE_TERMINATE_STATS" ]; then
    $PRE_TERMINATE_STATS
fi

echo "Run JVB graceful shutdown script"
/usr/share/jitsi-videobridge/graceful_shutdown.sh
