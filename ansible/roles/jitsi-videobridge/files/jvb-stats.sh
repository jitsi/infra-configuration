#!/bin/bash

readonly PROGNAME=$(basename "$0")
readonly LOCKFILE_DIR=/tmp
readonly LOCK_FD=300

LOCAL_STATS_DIR="/tmp/jvb-stats"
NUM_LOCAL_STATS_TO_KEEP=30

#pull our own instance and environment
. /usr/local/bin/aws_cache.sh

CURL_BIN="/usr/bin/curl"
AWS_BIN="/usr/local/bin/aws"

CURRENT_EC2_REGION=$($CURL_BIN -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$CURRENT_EC2_REGION

LOCK_SNS_TOPIC_ARN="arn:aws:sns:us-west-2:103425057857:scripts-lock-alarms"
SNS_FILE_PATH="/tmp/${PROGNAME}.txt"

function run_stats() {
  #now run the python that pushes stats to DD
  /usr/local/bin/jvb-stats.py
  JVB_RESTARTS="$(systemctl show jitsi-videobridge2.service -p NRestarts | cut -d= -f2)"
  echo -n "jitsi.JVB.restarts:${JVB_RESTARTS}|g|#systemd" | nc -4u -w1 localhost 8125
}

function send_to_sns() {
    
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

    echo -e "Script: ${PROGNAME}\nInstanceId: ${EC2_INSTANCE_ID}\nEnvironment: ${ENVIRONMENT}\nShard: ${SHARD}\nTime: ${timestamp}\n\n" > $SNS_FILE_PATH

    $AWS_BIN sns publish --region ${CURRENT_EC2_REGION} --topic-arn ${LOCK_SNS_TOPIC_ARN} \
    --message file://${SNS_FILE_PATH} --subject "Run script ${PROGNAME} was locked on instance ${EC2_INSTANCE_ID}" 
    
    rm -f ${SNS_FILE_PATH}

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

# Saves more detailed jvb stats locally for postmortem.
function save_stats_locally() {
    mkdir -p $LOCAL_STATS_DIR
    for stat in node-stats pool-stats queue-stats transit-stats task-pool-stats xmpp-delay-stats
    do
        # Rotate
        for i in $(seq $NUM_LOCAL_STATS_TO_KEEP -1 2)
        do
            mv -f "$LOCAL_STATS_DIR/$stat.$((i-1)).json" "$LOCAL_STATS_DIR/$stat.$i.json"
        done

        curl -s "http://localhost:8080/debug/stats/jvb/$stat" | jq . > "$LOCAL_STATS_DIR/$stat.1.json"
    done

    # Rotate and save /colibri/stats
    for i in $(seq $NUM_LOCAL_STATS_TO_KEEP -1 2)
    do
        mv -f "$LOCAL_STATS_DIR/stats.$((i-1)).json" "$LOCAL_STATS_DIR/stats.$i.json"
    done
    curl -s "http://localhost:8080/colibri/stats" | jq . > "$LOCAL_STATS_DIR/stats.1.json"
}

function main () {
    lock $PROGNAME \
        || eexit "Only one instance of $PROGNAME can run at one time."
    
    run_stats
    save_stats_locally
    
}

main
