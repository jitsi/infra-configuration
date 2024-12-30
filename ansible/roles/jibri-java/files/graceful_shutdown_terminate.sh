#!/bin/bash
GRACEFUL_SHUTDOWN="/opt/jitsi/jibri/wait_graceful_shutdown.sh"

AWS_BIN="$(which aws)"
CURL_BIN="/usr/bin/curl"

EC2_INSTANCE_ID=$(/usr/bin/ec2metadata --instance-id)
EC2_REGION=$($CURL_BIN -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION

# run the graceful shutdown and wait for it to finish
sudo $GRACEFUL_SHUTDOWN

# now terminate our instance
$AWS_BIN ec2 terminate-instances --instance-ids "$EC2_INSTANCE_ID"
