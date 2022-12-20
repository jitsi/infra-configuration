#!/bin/bash

SHARD_DATA="$1"
SHARD_DATA_TYPE="$2"
[ -z "$SHARD_DATA_TYPE" ] && SHARD_DATA_TYPE="shard-states"

if [ -z "$SHARD_DATA" ]; then
    echo "No shard state set."
    echo "Usage: $0 <state> [<type>]"
    exit 1
fi

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
consul kv put "$SHARD_KEY" "$SHARD_DATA"
exit $?