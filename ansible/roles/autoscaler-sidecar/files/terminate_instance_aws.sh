#!/bin/bash

CURL_BIN="/usr/bin/curl"
AWS_BIN="/usr/local/bin/aws"
JQ_BIN="/usr/bin/jq"

if [ -z "$INSTANCE_ID" ]; then
    INSTANCE_ID=$(/usr/bin/ec2metadata --instance-id)
fi

EC2_REGION=$($CURL_BIN -s http://169.254.169.254/latest/dynamic/instance-identity/document | $JQ_BIN .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION

# terminate our instance
$AWS_BIN ec2 terminate-instances --instance-ids "$INSTANCE_ID"
