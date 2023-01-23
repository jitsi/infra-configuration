#!/bin/bash
SHARD_DATA_SCRIPT="/usr/local/bin/set-shard-state-consul.sh"
SIGNAL_REPORT_URL="http://localhost:6000/signal/report"
STATS_FILE_PATH="/tmp/jicofo-stats.json"
LAST_STATS_FILE_PATH="/tmp/last-jicofo-stats.json"

PROSODY_JVB_DUMP_SCRIPT="/usr/local/bin/dump-prosody-jvb.sh"

if [ -e "$STATS_FILE_PATH" ]; then
    if [ -e "$LAST_STATS_FILE_PATH" ]; then
        # pull latest lost bridge count
        LOST_BRIDGES=$(cat $STATS_FILE_PATH | jq -r ".bridge_selector.lost_bridges")
        # pull previous lost bridges count for comparison
        LAST_LOST_BRIDGES=$(cat $LAST_STATS_FILE_PATH | jq -r ".bridge_selector.lost_bridges")

        # copy last stats for use in the next check
        cp $STATS_FILE_PATH $LAST_STATS_FILE_PATH

        # now compare last stats to current stats
        if [[ $LOST_BRIDGES -gt $LAST_LOST_BRIDGES ]]; then
            echo "Additional lost bridges detected, current count: $LOST_BRIDGES, changed from previous $LAST_LOST_BRIDGES"
            if [ -e "$PROSODY_JVB_DUMP_SCRIPT" ]; then
                sudo $PROSODY_JVB_DUMP_SCRIPT
            else
                echo "prosody-jvb script not present, no additional traceback available"
            fi
        else
            echo "No additional lost bridges detected, current count: $LOST_BRIDGES"
        fi
    else
        # no previous stats file found, so only copy last stats for use in the next check
        cp $STATS_FILE_PATH $LAST_STATS_FILE_PATH
    fi
fi

SIGNAL_REPORT=$(curl $SIGNAL_REPORT_URL)
if [ $? -eq 0 ]; then
    if [ -n "$SIGNAL_REPORT" ]; then
        $SHARD_DATA_SCRIPT "$SIGNAL_REPORT" "signal-report"
    fi
fi