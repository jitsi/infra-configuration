#!/bin/bash
set -e
set -x

# pull ENVIRONMENT, ORACLE_REGION and RELEASE_NUMBER
. /usr/local/bin/oracle_cache.sh

[ -z "$DUMP_BUCKET_NAME" ] && DUMP_BUCKET_NAME="stats-${ENVIRONMENT}"

OCI_BIN="/usr/local/bin/oci"
JSTAMP="$(date +%Y-%m-%dT%H%M)"
JHOST="$(hostname -s)"

[ -z "$DUMP_PATH" ] && DUMP_PATH="pre-terminate-stats/jigasi-release-${JIGASI_RELEASE_NUMBER}/$JHOST-$JSTAMP.tar.gz"

[ -z "$COLLECTION_FILENAME" ] && COLLECTION_FILENAME="$(mktemp -d)/jigasi-stats.tar.gz"
export COLLECTION_FILENAME
/usr/local/bin/collect-pre-terminate-stats-jigasi.sh

if [ ! -f "$COLLECTION_FILENAME" ]; then
    echo "No file found at $COLLECTION_FILENAME after running collect-pre-terminate-stats-jigasi.sh"
    exit 2
fi

$OCI_BIN os object put -bn "$DUMP_BUCKET_NAME" --name "$DUMP_PATH" --file "$COLLECTION_FILENAME" --metadata '{"environment":"'"$ENVIRONMENT"'","jigasi-release-number":"'"$JIGASI_RELEASE_NUMBER"'"}' --region "$ORACLE_REGION" --auth instance_principal

PATHS="$(/usr/bin/find /var/lib/tcpdump-jigasi -type f)"
for dumpfile in $PATHS; do
    DUMP_PATH="tcpdump-jigasi/jigasi-release-${JIGASI_RELEASE_NUMBER}/${JHOST}/$(basename $dumpfile)"
    $OCI_BIN os object put --force -bn "$DUMP_BUCKET_NAME" --name "$DUMP_PATH" --file "$dumpfile" --metadata '{"environment":"'"$ENVIRONMENT"'","jigasi-release-number":"'"$JIGASI_RELEASE_NUMBER"'"}' --region "$ORACLE_REGION" --auth instance_principal
done
