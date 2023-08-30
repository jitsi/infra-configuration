#!/bin/bash
. /usr/local/bin/oracle_cache.sh
[ -z "$DUMP_BUCKET_NAME" ] && DUMP_BUCKET_NAME="stats-${ENVIRONMENT}"
JHOST="$(hostname -s)"

PATHS="$(/usr/bin/find /var/lib/tcpdump-jigasi -type f -mmin +300)"
for dumpfile in $PATHS; do
    DUMP_PATH="tcpdump-jigasi/jigasi-release-${JIGASI_RELEASE_NUMBER}/${JHOST}/$(basename $dumpfile)"
    $OCI_BIN os object put --force -bn "$DUMP_BUCKET_NAME" --name "$DUMP_PATH" --file "$dumpfile" --metadata '{"environment":"'"$ENVIRONMENT"'","jigasi-release-number":"'"$JIGASI_RELEASE_NUMBER"'"}' --region "$ORACLE_REGION" --auth instance_principal

    /bin/rm -f $dumpfile
done
