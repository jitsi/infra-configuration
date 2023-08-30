#!/bin/bash

echo "Dump pre-terminate stats for Jigasi"
# this script is run from different users, e.g. jsidecar, ubuntu, root, and should not use sudo commands
PRE_TERMINATE_STATS="/usr/local/bin/dump-pre-terminate-stats-jigasi.sh"
if [ -x "$PRE_TERMINATE_STATS" ]; then
    $PRE_TERMINATE_STATS
fi

/usr/share/jigasi/graceful_shutdown.sh