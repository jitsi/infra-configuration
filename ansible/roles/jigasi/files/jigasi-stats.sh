#!/bin/bash

#pull our own instance and environment
. /usr/local/bin/aws_cache.sh

#now run the python that pushes stats to statsd
/usr/local/bin/jigasi-stats.py

#now run the cloudwatch reporting of these metrics
CLOUDWATCH_STATS_NAMESPACE="Video"

CURL_BIN="/usr/bin/curl"
AWS_BIN="/usr/local/bin/aws"
EC2_METADATA_BIN="/usr/bin/ec2metadata"

EC2_AVAIL_ZONE=$($CURL_BIN -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
EC2_REGION=$($CURL_BIN -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION

AUTO_SCALE_GROUP=$($AWS_BIN ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}" "Name=key,Values=aws:autoscaling:groupName" | jq .Tags[0].Value -r)

METRIC_TMP_FILE="/tmp/jigasi-metrics.json"
JIGASI_STAT_FILE="/tmp/jigasi-stats.json"

METRIC_DATA=''
METRIC_COUNT=0
METRIC_MAX=20


function getColibriStats() {
    cat $JIGASI_STAT_FILE
}

function sendStats() {
  cat > $METRIC_TMP_FILE<<TILLEND
{
    "Namespace": "$CLOUDWATCH_STATS_NAMESPACE",
    "MetricData": [ $METRIC_DATA ]
}

TILLEND
  $AWS_BIN cloudwatch put-metric-data --cli-input-json file://$METRIC_TMP_FILE
}

function checkSendStats() {
  NC=$1
  if [ $(($METRIC_COUNT+$NC)) -gt $METRIC_MAX ]; then
      #we went over, so send metrics and reset
    sendStats
    METRIC_DATA=''
    METRIC_COUNT=0
  fi
}

function addNewMetrics() {
  ND=$1
  NC=$2
  checkSendStats $NC

  METRIC_COUNT=$(($METRIC_COUNT+$NC))
  #we have ASG so report those metrics too
  if [ -z "$METRIC_DATA" ]; then
    #avoiding beginning comma
    METRIC_DATA=$ND
  else
    METRIC_DATA="$METRIC_DATA,$ND"
  fi
}

function pushMetricValues() {
      metricName=$1
      statVal=$2
      statUnits=$3
      NEW_METRIC_COUNT=2
      NEW_METRIC_DATA=$(cat <<TILLEND
          {
              "MetricName": "$metricName",
              "Dimensions": [
                  {
                      "Name": "InstanceId",
                      "Value": "$EC2_INSTANCE_ID"
                  }
              ],
              "Timestamp": "$TIMESTAMP",
              "Value": $statVal,
              "Unit": "$statUnits"
          },
          {
              "MetricName": "$metricName",
              "Dimensions": [
                  {
                      "Name": "Environment",
                      "Value": "$ENVIRONMENT"
                  }
              ],
              "Timestamp": "$TIMESTAMP",
              "Value": $statVal,
              "Unit": "$statUnits"
          }
TILLEND
)


      if [ -n "$AUTO_SCALE_GROUP" ]; then
        #add one to the count
        NEW_METRIC_COUNT=$(($NEW_METRIC_COUNT+1))
        ASG_METRIC_DATA=$(cat <<TILLEND
          {
              "MetricName": "$metricName",
              "Dimensions": [
                  {
                      "Name": "AutoScalingGroupName",
                      "Value": "$AUTO_SCALE_GROUP"
                  }
              ],
              "Timestamp": "$TIMESTAMP",
              "Value": $statVal,
              "Unit": "$statUnits"
          }
TILLEND
)
        #we have ASG so report those metrics too
        NEW_METRIC_DATA="$NEW_METRIC_DATA,$ASG_METRIC_DATA"
      fi

      addNewMetrics "$NEW_METRIC_DATA" $NEW_METRIC_COUNT  
}

STATS=`getColibriStats`

TIMESTAMP=`date +%FT%T`

for statKey in `echo $STATS | jq "keys[]"| sed -e 's/^"//'  -e 's/"$//'`; do

  # We are interested only in the participants stat.
  # It is used for autoscaling.
  if [ "$statKey" != "participants" ]; then
    continue;
  fi

  #strip off any beginning or ending quotes on values, also change boolean true/false to 1/0
  statVal=$(echo $STATS | jq ".$statKey"| sed -e 's/^"//'  -e 's/"$//' -e 's/false/0/' -e 's/true/1/')
  #don't report timestamp
  if [ "$statKey" == "current_timestamp" ]; then
    statTS=$statVal
  elif [ "$statKey" == "conference_sizes" ]; then
    conferenceSizeStats=$(echo $statVal | jq '. | keys[] as $i | {("conference_count_"+($i|tostring)):.[$i]}' | jq -s '.|add')
    for sizeStatKey in `echo $conferenceSizeStats | jq -r "keys[]"`; do
      statVal=$(echo $conferenceSizeStats | jq -r ".$sizeStatKey")
      statUnits="Count"
      metricName="jigasi_$sizeStatKey"
      pushMetricValues $metricName $statVal $statUnits
    done

  else

    statUnits="None"
    [ "$statKey" == "audiochannels" ] && statUnits="Count"
    [ "$statKey" == "bit_rate_download" ] && statUnits="Kilobits/Second"
    [ "$statKey" == "bit_rate_upload" ] && statUnits="Kilobits/Second"
    [ "$statKey" == "conferences" ] && statUnits="Count"
    [ "$statKey" == "cpu_usage" ] && statUnits="Percent"
    [ "$statKey" == "graceful_shutdown" ] && statUnits="None"
    [ "$statKey" == "participants" ] && statUnits="Count"
    [ "$statKey" == "largest_conference" ] && statUnits="Count"
    [ "$statKey" == "rtp_loss" ] && statUnits="Percent"
    [ "$statKey" == "threads" ] && statUnits="Count"
    [ "$statKey" == "total_memory" ] && statUnits="Count"
    [ "$statKey" == "used_memory" ] && statUnits="Count"
    [ "$statKey" == "videochannels" ] && statUnits="Count"
    [ "$statKey" == "videostreams" ] && statUnits="Count"
    [ "$statKey" == "total_conference_seconds" ] && statUnits="Seconds"
    [ "$statKey" == "total_conferences_created" ] && statUnits="Count"
    [ "$statKey" == "total_conferences_completed" ] && statUnits="Count"
    [ "$statKey" == "total_partially_failed_conferences" ] && statUnits="Count"
    [ "$statKey" == "total_failed_conferences" ] && statUnits="Count"
    [ "$statKey" == "total_no_transport_channels" ] && statUnits="Count"
    [ "$statKey" == "total_no_payload_channels" ] && statUnits="Count"
    [ "$statKey" == "total_udp_connections" ] && statUnits="Count"
    [ "$statKey" == "total_tcp_connections" ] && statUnits="Count"
    [ "$statKey" == "packet_rate_download" ] && statUnits="Count/Second"
    [ "$statKey" == "packet_rate_upload" ] && statUnits="Count/Second"
    [ "$statKey" == "loss_rate_download" ] && statUnits="Percent"
    [ "$statKey" == "loss_rate_upload" ] && statUnits="Percent"
    [ "$statKey" == "rtt_aggregate" ] && statUnits="Milliseconds"
    [ "$statKey" == "jitter_aggregate" ] && statUnits="Milliseconds"
    
    metricName="jigasi_$statKey"
    pushMetricValues $metricName $statVal $statUnits

  fi
done

if [ -n "$METRIC_DATA" ]; then
  sendStats
fi
rm $METRIC_TMP_FILE
