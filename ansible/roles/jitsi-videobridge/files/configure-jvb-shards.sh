#!/bin/bash

SHARD_FILE=/etc/jitsi/videobridge/shards.json
UPLOAD_FILE=/etc/jitsi/videobridge/upload.json
DRAIN_URL="http://localhost:8080/colibri/drain"
LIST_URL="http://localhost:8080/colibri/muc-client/list"
ADD_URL="http://localhost:8080/colibri/muc-client/add"
REMOVE_URL="http://localhost:8080/colibri/muc-client/remove"

DRAIN_MODE=$(cat $SHARD_FILE | jq -r ".drain_mode")
DOMAIN=$(cat $SHARD_FILE | jq -r ".domain")
USERNAME=$(cat $SHARD_FILE | jq -r ".username")
PASSWORD=$(cat $SHARD_FILE | jq -r ".password")
MUC_JIDS=$(cat $SHARD_FILE | jq -r ".muc_jids")
MUC_NICKNAME=$(cat $SHARD_FILE | jq -r ".muc_nickname")
IQ_HANDLER_MODE=$(cat $SHARD_FILE | jq -r ".iq_handler_mode")
DISABLE_CERT_VERIFY="true"
XMPP_PORT=$(cat $SHARD_FILE | jq -r ".port")

SHARDS=$(cat $SHARD_FILE | jq -r ".shards|keys|.[]")
for SHARD in $SHARDS; do
    echo "Adding shard $SHARD"
    SHARD_IP=$(cat $SHARD_FILE | jq -r ".shards.\"$SHARD\".xmpp_host_private_ip_address")
    SHARD_PORT=$(cat $SHARD_FILE | jq -r ".shards.\"$SHARD\".host_port")
    if [[ "$SHARD_PORT" == "null" ]]; then
        SHARD_PORT=$XMPP_PORT
    fi
    T="
{
    \"id\":\"$SHARD\",
    \"domain\":\"$DOMAIN\",
    \"hostname\":\"$SHARD_IP\",
    \"port\":\"$SHARD_PORT\",
    \"username\":\"$USERNAME\",
    \"password\":\"$PASSWORD\",
    \"muc_jids\":\"$MUC_JIDS\",
    \"muc_nickname\":\"$MUC_NICKNAME\",
    \"iq_handler_mode\":\"$IQ_HANDLER_MODE\",
    \"disable_certificate_verification\":\"$DISABLE_CERT_VERIFY\"
}"

    #configure JVB to know about shard via POST
    echo $T > $UPLOAD_FILE
    curl --data-binary "@$UPLOAD_FILE" -H "Content-Type: application/json" $ADD_URL
    rm $UPLOAD_FILE
done

LIVE_DRAIN_MODE="$(curl $DRAIN_URL | jq '.drain')"
if [[ "$DRAIN_MODE" == "true" ]]; then
    if [[ "$LIVE_DRAIN_MODE" == "false" ]]; then
        echo "Drain mode is requested, draining JVB"
        curl -d "" "$DRAIN_URL/enable"
    fi
fi
if [[ "$DRAIN_MODE" == "false" ]]; then
    if [[ "$LIVE_DRAIN_MODE" == "true" ]]; then
        echo "Drain mode is disabled, setting JVB to ready"
        curl -d "" "$DRAIN_URL/disable"
    fi
fi

LIVE_SHARD_ARR="$(curl $LIST_URL)"
FILE_SHARD_ARR="$(cat $SHARD_FILE | jq ".shards|keys")"
REMOVE_SHARDS=$(jq -r -n --argjson FILE_SHARD_ARR "$FILE_SHARD_ARR" --argjson LIVE_SHARD_ARR "$LIVE_SHARD_ARR" '{"live": $LIVE_SHARD_ARR,"file":$FILE_SHARD_ARR} | .live-.file | .[]')

for SHARD in $REMOVE_SHARDS; do
    echo "Removing shard $SHARD"
    curl -H "Content-Type: application/json" -X POST -d "{\"id\":\"$SHARD\"}" $REMOVE_URL 
done