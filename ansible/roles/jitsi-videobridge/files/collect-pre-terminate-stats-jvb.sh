#!/bin/bash

set -x

[ -z "$COLLECTION_FILENAME" ] && COLLECTION_FILENAME="$(mktemp -d)/jvb-stats.tar.gz"
echo "Will collect stats in $COLLECTION_FILENAME"

DIR=$(mktemp -d)

cd $DIR

for i in payload-verification node-stats pool-stats queue-stats transit-stats task-pool-stats \
  ice-stats xmpp-delay-stats tossed-packet-stats conference-packet-stats; do
    curl -s 0:8080/debug/stats/jvb/$i | jq . > $i.json
done

curl -s 0:8080/colibri/stats | jq . > colibri-stats.json
curl -s 0:8080/metrics | jq . > metrics.json

tar czf jvb-stats.tar.gz *
cd -
mv "${DIR}/jvb-stats.tar.gz" "$COLLECTION_FILENAME"