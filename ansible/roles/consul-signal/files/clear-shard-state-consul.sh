#!/bin/bash

SHARD_DATA_TYPE="$1"
[ -z "$SHARD_DATA_TYPE" ] && SHARD_DATA_TYPE="shard-states"

AWS_CACHE_BIN="/usr/local/bin/aws_cache.sh"
ORACLE_CACHE_BIN="/usr/local/bin/oracle_cache.sh"
if [ -e "$ORACLE_CACHE_BIN" ]; then
    . $ORACLE_CACHE_BIN
else
    . $AWS_CACHE_BIN
fi
if [ "$DOMAIN" == "null" ]; then
    DOMAIN=$(hostname)
fi

if [ "$SHARD" == "null" ]; then
    SHARD="$DOMAIN"
fi
SHARD_KEY="$SHARD_DATA_TYPE/$ENVIRONMENT/$SHARD"
consul kv delete "$SHARD_KEY"
exit $?