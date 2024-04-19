#!/bin/bash

export OCI_BIN="/usr/local/bin/oci"
export CURL_BIN="/usr/bin/curl"
export JQ_BIN="/usr/bin/jq"

# notify the sidecar of imminent shutdown
$CURL_BIN -d '{}' -v localhost:6000/hook/v1/shutdown
sleep 10

if [ -z "$INSTANCE_ID" ]; then
    INSTANCE_ID=$($CURL_BIN -s http://169.254.169.254/opc/v1/instance/ | $JQ_BIN .id -r)
fi

# terminate our instance; we enable debug to have more details in case of oci cli failures
$OCI_BIN compute instance terminate --debug --instance-id "$INSTANCE_ID" --preserve-boot-volume false --auth instance_principal --force
