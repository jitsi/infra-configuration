#!/bin/bash

#pull our own instance and environment
. /usr/local/bin/oracle_cache.sh

#now run the python that pushes stats to DD
/usr/local/bin/jvb-stats.py

JVB_RESTARTS="$(systemctl show jitsi-videobridge2.service -p NRestarts | cut -d= -f2)"
echo -n "jitsi.JVB.restarts:${JVB_RESTARTS}|g|#systemd" | nc -4u -w1 localhost 8125

# Save more detailed jvb stats locally for postmortem.
LOCAL_STATS_DIR="/tmp/jvb-stats"
NUM_LOCAL_STATS_TO_KEEP=30
mkdir -p $LOCAL_STATS_DIR
for stat in node-stats pool-stats queue-stats transit-stats task-pool-stats xmpp-delay-stats
do
    # Rotate
    for i in $(seq $NUM_LOCAL_STATS_TO_KEEP -1 2)
    do
        mv -f "$LOCAL_STATS_DIR/$stat.$((i-1)).json" "$LOCAL_STATS_DIR/$stat.$i.json"
    done

    curl -s http://localhost:8080/debug/stats/jvb/$stat | jq . > "$LOCAL_STATS_DIR/$stat.1.json"
done
