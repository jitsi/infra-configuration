#!/bin/bash

set -x

[ -z "$COLLECTION_FILENAME" ] && COLLECTION_FILENAME="$(mktemp -d)/jigasi-stats.tar.gz"
echo "Will collect stats in $COLLECTION_FILENAME"

DIR=$(mktemp -d)

cd $DIR

curl -s 0:8788/about/stats | jq . > stats.json

tar czf jigasi-stats.tar.gz *
cd -
mv "${DIR}/jigasi-stats.tar.gz" "$COLLECTION_FILENAME"
