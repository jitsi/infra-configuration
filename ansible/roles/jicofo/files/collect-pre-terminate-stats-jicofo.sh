#!/bin/bash

set -x

[ -z "$COLLECTION_FILENAME" ] && COLLECTION_FILENAME="$(mktemp -d)/jicofo-stats.tar.gz"
echo "Will collect stats in $COLLECTION_FILENAME"

DIR=$(mktemp -d)

cd $DIR

curl -s 0:8888/debug/xmpp-caps | jq . > xmpp-caps.json
curl -s 0:8888/stats | jq . > stats.json
curl -s 0:8888/metrics | jq . > metrics.json

tar czf jicofo-stats.tar.gz *
mv jicofo-stats.tar.gz "$COLLECTION_FILENAME"