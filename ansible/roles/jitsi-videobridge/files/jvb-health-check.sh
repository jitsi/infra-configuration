#!/bin/bash

readonly PROGNAME=$(basename "$0")
readonly LOCKFILE_DIR=/tmp
readonly LOCK_FD=200

#PULL IN SHARD, ENVIRONMENT, EC2_INSTANCE_ID
. /usr/local/bin/aws_cache.sh

#only allow curl to run for this many seconds
HEALTH_CHECK_TIMEOUT=30

HEALTH_URL="http://localhost:8080/about/health"
CONFERENCE_URL="http://localhost:8080/colibri/v2/conferences/"
HEALTH_OUTPUT="/tmp/health-check-output"
HEALTH_FAILURE_FILE="/tmp/health-check-fails"
IP_FAILED_FILE="/tmp/health-check-ip-fails"
CRITICAL_FAILURE_THRESHOLD=3
HEALTH_FAIL_LOCK_FILE="/tmp/jvb-unhealthy-lock"
MINIMUM_IP_COUNT=1
JVB_USER="jvb"
LOAD_THRESHOLD=100


#maximum number of seconds to wait before unhealthy bridge is terminated
SLEEP_MAX=$((3600*6))

#check every interval to see if bridge is done shutting down
SLEEP_INTERVAL=60

GRACEFUL_SHUTDOWN_FILE="/tmp/graceful-shutdown-output"

CURL_BIN="/usr/bin/curl"
AWS_BIN="/usr/local/bin/aws"

CURRENT_EC2_REGION=$($CURL_BIN -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$CURRENT_EC2_REGION
#source variables come from aws_cache.sh sourced above
CLOUDWATCH_DIMENSIONS="InstanceId=$EC2_INSTANCE_ID,Environment=$ENVIRONMENT,Shard=$SHARD"
[ -z "$SHARD" ] && CLOUDWATCH_DIMENSIONS="InstanceId=$EC2_INSTANCE_ID,Environment=$ENVIRONMENT"

LOCK_SNS_TOPIC_ARN="arn:aws:sns:us-west-2:103425057857:scripts-lock-alarms"
SNS_FILE_PATH="/tmp/${PROGNAME}.txt"

function send_to_sns() {

    timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

    echo -e "Script: ${PROGNAME}\nInstanceId: ${EC2_INSTANCE_ID}\nEnvironment: ${ENVIRONMENT}\nShard: ${SHARD}\nTime: ${timestamp}\n" > $SNS_FILE_PATH

    $AWS_BIN sns publish --region ${CURRENT_EC2_REGION} --topic-arn ${LOCK_SNS_TOPIC_ARN} \
    --message file://${SNS_FILE_PATH} --subject "Run script ${PROGNAME} was locked on instance ${EC2_INSTANCE_ID}"

    rm -f ${SNS_FILE_PATH}

}

function run_check() {

$CURL_BIN --max-time $HEALTH_CHECK_TIMEOUT -f $HEALTH_URL > $HEALTH_OUTPUT 2>&1
if [ $? -eq 0 ]; then
    echo "Basic health OK"
    BASIC_HEALTH_PASSED=true
else
  echo "Basic health failed"
  BASIC_HEALTH_PASSED=false
fi

if [ -e "$IP_FAILED_FILE" ]; then
  CANDIDATE_IPS=$(cat $IP_FAILED_FILE)
else
  CANDIDATE_IPS=0
fi

# Create a conference with a randoom name. No need to worry about expiring it, because it will time out on the bridge.
read -r -d '' SIMPLE_COLIBRI_TO_GET_IPS << EOM
{
  "create" : true,
  "meeting-id":"`uuidgen`",
  "endpoints":[
    {
      "create": true,
      "id":"ep-id",
      "transport": {"ice-controlling":true}
    }
  ]
}
EOM

if [ "$CANDIDATE_IPS" -ge "$MINIMUM_IP_COUNT" ]; then
  #skip the check since we are passing
  echo "Skipping candidate IP check, already passing"
  EXTENDED_HEALTH_PASSED=true
else
  #wait a few seconds before checking the IP addresses the JVB hands out
  echo "Testing for candidate IPs"
  CANDIDATE_JSON=$($CURL_BIN --max-time $HEALTH_CHECK_TIMEOUT -H"Content-Type: application/json" -d "${SIMPLE_COLIBRI_TO_GET_IPS}" 2>/tmp/jvb_candidates_cron_error $CONFERENCE_URL)
  CANDIDATE_IPS=$(echo $CANDIDATE_JSON | jq -r '.endpoints[0].transport.transport.candidates[].ip' | sort | uniq)

  #hack to count items by whitespace by making them an array and splitting them
  VAR=( $CANDIDATE_IPS )
  CANDIDATE_IP_COUNT=${#VAR[@]}

  echo "$CANDIDATE_IP_COUNT" > $IP_FAILED_FILE

  if [ "$CANDIDATE_IP_COUNT" -ge "$MINIMUM_IP_COUNT" ]; then
    echo "candidate IP check OK"
    EXTENDED_HEALTH_PASSED=true
  else
    echo "candidate IP check failed: $CANDIDATE_IP_COUNT not greater than $MINIMUM_IP_COUNT"
    echo "candidate IPS: $CANDIDATE_IPS"
    echo "candidate JSON: $CANDIDATE_JSON"
    EXTENDED_HEALTH_PASSED=false
  fi
fi

# check load against threshold with immediate health dump behavior
LOAD_1=$(awk '{print $1}' /proc/loadavg)
LOAD_1_INT=$(echo $LOAD_1 | cut -d'.' -f1)

if [[ $LOAD_1_INT -ge $LOAD_THRESHOLD ]]; then
  echo "Load $LOAD_1 HIGHER THAN $LOAD_THRESHOLD"
  echo "Dumping immediately"
  BASIC_HEALTH_PASSED=false
  # ensure dump happens immediately by overriding the failure count
  echo $((CRITICAL_FAILURE_THRESHOLD+1)) > $HEALTH_FAILURE_FILE
fi

if $BASIC_HEALTH_PASSED && $EXTENDED_HEALTH_PASSED; then
    [ -e $HEALTH_FAILURE_FILE ] && rm $HEALTH_FAILURE_FILE
    HEALTH_CHECK_VALUE=1
else
    if [ -e $HEALTH_FAILURE_FILE ]; then
      CHECK_COUNT=$(( $(cat $HEALTH_FAILURE_FILE) +  1))
    else
      CHECK_COUNT=1
    fi

	echo $CHECK_COUNT > $HEALTH_FAILURE_FILE
  if [ $CHECK_COUNT -gt $CRITICAL_FAILURE_THRESHOLD ]; then

    #only dump memory and set unhealth once, then write to lock file and never do it again unless lock is cleared
    if [ ! -f $HEALTH_FAIL_LOCK_FILE ]; then
      echo 'Unhealthy' > $HEALTH_FAIL_LOCK_FILE
      #Begin graceful shutdown of JVB in a background process
      sudo /usr/share/jitsi-videobridge/graceful_shutdown.sh > $GRACEFUL_SHUTDOWN_FILE 2>&1 &

      #Dump all JVB logs to S3, must do this as root to access all needed information
      sudo /usr/local/bin/dump-jvb.sh

      #only terminate instance is auto scale group is defined
      if [ -n "$AUTO_SCALE_GROUP" ]; then
        #Detach our instance from the autoscaling group so a new JVB can replace us
        $AWS_BIN autoscaling detach-instances --instance-ids "$EC2_INSTANCE_ID" --auto-scaling-group-name "$AUTO_SCALE_GROUP" --no-should-decrement-desired-capacity


        #wait for our requisite time and then terminate ourselves
        #loop and check if process is running, then terminate after final countdown
        ST=0
        FINISHED=false
        while true; do
          sleep $SLEEP_INTERVAL
          ST=$(($ST+$SLEEP_INTERVAL))
          PID=$(/bin/systemctl show -p MainPID jitsi-videobridge | cut -d '=' -f2)
          if [[ $PID > 0 ]]; then
            #attempt to poke the process to determine if it's still alive
            sudo -u $JVB_USER kill -0 $PID
            if [[ $? == 0 ]]; then
              #wait a bit more, unless our sleep interval is greater than the max
              if [[ $ST -ge $SLEEP_MAX ]]; then
                FINISHED=true
              fi
            else
              #system says the PID is there but process is missing, so we're done
              FINISHED=true
            fi
          else
            #JVB finished shutting down, so finish up
            FINISHED=true
          fi
          if $FINISHED; then

            echo "Clean up the Route53 DNS"
            # this script is run from different users, e.g. jsidecar, ubuntu, root, and should not use sudo commands
            CLEANUP_ROUTE53_DNS="/usr/local/bin/cleanup_route53_dns.sh"
            if [ -f "$CLEANUP_ROUTE53_DNS" ]; then
                $CLEANUP_ROUTE53_DNS
            fi

            $AWS_BIN ec2 terminate-instances --instance-ids "$EC2_INSTANCE_ID"
          fi
        done
        #Failure is really critical, so mark our instance as unhealthy
      fi
    fi
  fi

fi
}

function lock() {
    local prefix=$1
    local fd=${2:-$LOCK_FD}
    local lock_file=$LOCKFILE_DIR/$prefix.lock

    # create lock file
    eval "exec $fd>$lock_file"

    # acquier the lock
    flock -n $fd \
        && return 0 \
        || return 1
}

function eexit() {
    local error_str="$@"

    echo $error_str
    send_to_sns

    exit 1
}

function main () {
    lock $PROGNAME \
        || eexit "Only one instance of $PROGNAME can run at one time."

    run_check
}

main

