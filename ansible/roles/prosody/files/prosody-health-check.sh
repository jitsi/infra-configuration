#!/bin/bash

readonly PROGNAME=$(basename "$0")
readonly LOCKFILE_DIR=/tmp
readonly LOCK_FD=200

#PULL IN SHARD, ENVIRONMENT, EC2_INSTANCE_ID
. /usr/local/bin/aws_cache.sh

#only allow curl to run for this many seconds
HEALTH_CHECK_TIMEOUT=3

HEALTH_URL="http://localhost:5280/http-bind"
HEALTH_OUTPUT="/tmp/prosody-health-check-output"
HEALTH_FAILURE_FILE="/tmp/prosody-health-check-fails"
CRITICAL_FAILURE_THRESHHOLD=3
CLOUDWATCH_HEALTH_NAMESPACE="System/Linux"
CLOUDWATCH_HEALTH_METRIC="ProsodyHealthCheckStatus"
CLOUDWATCH_HEALTH_METRIC_LOCK="ProsodyHealthCheckStatusLocked"
HEALTH_FAIL_LOCK_FILE="/tmp/prosody-unhealthy-lock"

TRACEBACK_PATH="/var/lib/prosody/traceback.txt"
# wait up to 2 minutes for traceback file
TRACEBACK_WAIT_TIMEOUT=120

S3_BUCKET="jitsi-infra-dumps"
SNS_TOPIC_ARN="arn:aws:sns:us-west-2:103425057857:JVB-Dumps"

# check every 10 seconds for traceback file
TRACEBACK_SLEEP_INTERVAL=10

CURL_BIN="/usr/bin/curl"
AWS_BIN="/usr/local/bin/aws"

export AWS_DEFAULT_REGION="us-west-2"
#source variables come from aws_cache.sh sourced above
CLOUDWATCH_DIMENSIONS="InstanceId=$EC2_INSTANCE_ID,Environment=$ENVIRONMENT,Shard=$SHARD"
[ -z "$SHARD" ] && CLOUDWATCH_DIMENSIONS="InstanceId=$EC2_INSTANCE_ID,Environment=$ENVIRONMENT"

LOCK_SNS_TOPIC_ARN="arn:aws:sns:us-west-2:103425057857:scripts-lock-alarms"
SNS_FILE_PATH="/tmp/${PROGNAME}.txt"

JSTAMP=$(date +%Y-%m-%d-%H%M)
JHOST=$(hostname -s)

function send_to_sns() {

    timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

    echo -e "Script: ${PROGNAME}\nHost: ${JHOST}\nInstanceId: ${EC2_INSTANCE_ID}\nEnvironment: ${ENVIRONMENT}\nShard: ${SHARD}\nTime: ${timestamp}\n\nYou could check lock statistic in CloudWatch by metric name: ${CLOUDWATCH_HEALTH_METRIC_LOCK}" > "$SNS_FILE_PATH"

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

    if $BASIC_HEALTH_PASSED; then
        [ -e $HEALTH_FAILURE_FILE ] && rm $HEALTH_FAILURE_FILE
        [ -e $HEALTH_FAIL_LOCK_FILE ] && rm $HEALTH_FAIL_LOCK_FILE
    else
        if [ -e $HEALTH_FAILURE_FILE ]; then
            CHECK_COUNT=$(( $(cat $HEALTH_FAILURE_FILE) +  1))
        else
            CHECK_COUNT=1
        fi

        echo $CHECK_COUNT > $HEALTH_FAILURE_FILE
        if [ $CHECK_COUNT -ge $CRITICAL_FAILURE_THRESHHOLD ]; then

            #only dump traceback and set unhealthy once, then write to lock file and never do it again unless lock is cleared
            if [ ! -f $HEALTH_FAIL_LOCK_FILE ]; then
                echo 'Unhealthy' > $HEALTH_FAIL_LOCK_FILE

                #Begin traceback dump of prosody

                #clear old traceback if present
                [ -e "$TRACEBACK_PATH" ] && rm $TRACEBACK_PATH

                PROSODY_PID=$(systemctl show --property MainPID --value prosody)
                if [ $? -eq 0 ]; then
                    if [ ! -z "$PROSODY_PID" ]; then
                        kill -USR1 $PROSODY_PID
                        # now wait until traceback file is present
                        SLEEP_TIMER=0
                        while :; do

                            sleep $TRACEBACK_SLEEP_INTERVAL;

                            if [ -e "$TRACEBACK_PATH" ]; then
                                # found traceback so break
                                break;
                            fi
                            if [ $SLEEP_TIMER -ge $TRACEBACK_WAIT_TIMEOUT ]; then
                                # TODO: notify somebody about this
                                echo "WAITED $TRACEBACK_WAIT_TIMEOUT FOR TRACEBACK, NEVER APPEARED"
                                break;
                            fi
                            SLEEP_TIMER=$(( SLEEP_TIMER + TRACEBACK_SLEEP_INTERVAL ))
                            echo "No traceback found, sleeping for $TRACEBACK_SLEEP_INTERVAL seconds"
                        done
                    fi
                fi

                # now check for traceback, if exists then copy it to s3
                if [ -e "$TRACEBACK_PATH" ]; then

                    TB_PATH="traceback_${JHOST}_${JSTAMP}.txt"

                    DUMP_PATH="s3://${S3_BUCKET}/prosody/$TB_PATH"

                    $AWS_BIN s3 cp $TRACEBACK_PATH $DUMP_PATH

                    MESSAGE="Prosody failure traceback available at: $DUMP_PATH"
                    $AWS_BIN sns publish --topic-arn=$SNS_TOPIC_ARN --message="$MESSAGE"
                else
                    MESSAGE="Prosody failure traceback unavailable from $JHOST at $JSTAMP"
                    $AWS_BIN sns publish --topic-arn=$SNS_TOPIC_ARN --message="$MESSAGE"
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
