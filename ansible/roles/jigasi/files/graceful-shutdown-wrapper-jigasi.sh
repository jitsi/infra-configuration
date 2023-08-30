#!/bin/bash

echo "Dump pre-terminate stats for Jigasi"
# this script is run from different users, e.g. jsidecar, ubuntu, root, and should not use sudo commands
PRE_TERMINATE_STATS="/usr/local/bin/dump-pre-terminate-stats-jigasi.sh"
if [ -x "$PRE_TERMINATE_STATS" ]; then
    $PRE_TERMINATE_STATS
fi

/usr/share/jigasi/graceful_shutdown.sh

. /usr/local/bin/oracle_cache.sh
JHOST="$(hostname -s)"
[ -z "$DUMP_BUCKET_NAME" ] && DUMP_BUCKET_NAME="stats-${ENVIRONMENT}"
PATHS="$(/usr/bin/find /var/lib/tcpdump-jigasi -type f)"
for dumpfile in $PATHS; do
    DUMP_PATH="tcpdump-jigasi/jigasi-release-${JIGASI_RELEASE_NUMBER}/${JHOST}/$(basename $dumpfile)"
    $OCI_BIN os object put --force -bn "$DUMP_BUCKET_NAME" --name "$DUMP_PATH" --file "$dumpfile" --metadata '{"environment":"'"$ENVIRONMENT"'","jigasi-release-number":"'"$JIGASI_RELEASE_NUMBER"'"}' --region "$ORACLE_REGION" --auth instance_principal
done
