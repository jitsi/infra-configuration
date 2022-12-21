#!/bin/bash

#PULL IN THE LOCAL ENVIRONMENT, DOMAIN, EC2_INSTANCE_ID, AWS_BIN, etc
. /usr/local/bin/aws_cache.sh

CURL_BIN="/usr/bin/curl"
NC_BIN="/bin/nc"

LAST_STATUS_FILE="/tmp/jibri-last-status"

STATUS_URL="http://localhost:2222/jibri/api/v1.0/health"

EC2_AVAIL_ZONE=`$CURL_BIN -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
EC2_REGION=$($CURL_BIN -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION

METRIC_COUNT=0
METRIC_DATA=''
METRIC_MAX=20
STATUS_TIMEOUT=30

function getJibriStatus() {
    $CURL_BIN --max-time $STATUS_TIMEOUT $STATUS_URL 2>/dev/null
}

#pessimism FTW
availableValue=0
healthyValue=0
recordingValue=0
lastRecordingValue=0
STATUS=`getJibriStatus`
if [ $? == 0 ]; then
  #parse status into pieces
  recordingStatus=$(echo $STATUS | jq -r ".status.busyStatus")
  healthyStatus=$(echo $STATUS | jq -r ".status.health.healthStatus")

  environmentStatus=$(echo $STATUS | jq -r ".environmentContext.name")

  if [ "$environmentStatus" == "null" ]; then
    environmentStatus=""
  fi

  if [ -z "$environmentStatus" ]; then
    environmentStatus=$ENVIRONMENT
  fi

  #if we got a jibri response we're probably healthy?
  if [[ $healthyStatus == "HEALTHY" ]]; then
    healthyValue=1
  else
    healthyValue=0
  fi

  #mostly assume recording is available unless recording status is BUSY
  if [[ "$recordingStatus" == "BUSY" ]]; then
    availableValue=0
    recordingValue=1
  else
    availableValue=1
    recordingValue=0
  fi

  LAST_STATUS=$(cat $LAST_STATUS_FILE)
  echo $STATUS > $LAST_STATUS_FILE
  lastRecordingStatus=$(echo $LAST_STATUS | jq -r ".status.busyStatus")
  lastHealthyStatus=$(echo $LAST_STATUS | jq -r ".status.health.healthStatus")

  if [[ "$lastRecordingStatus" == "BUSY" ]]; then
    lastRecordingValue=1
  else
    lastRecordingValue=0
  fi

  if [[ $lastRecordingValue != $recordingValue ]]; then
    # change in recording status, act accordingly
    if [[ $recordingValue == 1 ]]; then
      # begin recording
      if [ ! -z "$AUTO_SCALE_GROUP" ]; then
        # set instance protection, if we are in an ASG
        $AWS_BIN autoscaling set-instance-protection --protected-from-scale-in --instance-ids $EC2_INSTANCE_ID --auto-scaling-group-name $AUTO_SCALE_GROUP
      fi
    else
      # end recording
      if [ ! -z "$AUTO_SCALE_GROUP" ]; then
        # clear instance protection, if we are in an ASG
        $AWS_BIN autoscaling set-instance-protection --no-protected-from-scale-in --instance-ids $EC2_INSTANCE_ID --auto-scaling-group-name $AUTO_SCALE_GROUP
      fi
    fi
  fi

fi

#if jibri is unhealthy, mark it as unavailable as well
if [[ $healthyValue -eq 0 ]]; then
    availableValue=0
fi

# send metrics to statsd
echo "jibri.available:$availableValue|g" | $NC_BIN -C -w 1 -u localhost 8125
echo "jibri.healthy:$healthyValue|g" | $NC_BIN -C -w 1 -u localhost 8125
echo "jibri.recording:$recordingValue|g" | $NC_BIN -C -w 1 -u localhost 8125

