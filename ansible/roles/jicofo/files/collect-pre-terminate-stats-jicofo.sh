#!/bin/bash

PROSODY_AUDIT_LOG_FILE="/var/log/prosody/prosody.audit.log"
set -x

[ -z "$COLLECTION_FILENAME" ] && COLLECTION_FILENAME="$(mktemp -d)/jicofo-stats.tar.gz"
echo "Will collect stats in $COLLECTION_FILENAME"

DIR=$(mktemp -d)

cd $DIR

curl -s 0:8888/debug/xmpp-caps | jq . > xmpp-caps.json
curl -s 0:8888/stats | jq . > stats.json
curl -s 0:8888/metrics | jq . > metrics.json
[ -f "${PROSODY_AUDIT_LOG_FILE}" ] && cp ${PROSODY_AUDIT_LOG_FILE} .

tar czf jicofo-stats.tar.gz *
cd -
mv "${DIR}/jicofo-stats.tar.gz" "$COLLECTION_FILENAME"
