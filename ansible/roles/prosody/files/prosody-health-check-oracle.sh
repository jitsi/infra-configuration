#!/bin/bash

PROGNAME=$(basename "$0")
readonly PROGNAME

LOCKFILE_DIR="/tmp"
readonly LOCKFILE_DIR

LOCK_FD="200"
readonly LOCK_FD

#PULL IN SHARD, ENVIRONMENT, OCI stuff
. /usr/local/bin/oracle_cache.sh

#only allow curl to run for this many seconds
HEALTH_CHECK_TIMEOUT=3

HEALTH_URL="http://localhost:5280/http-bind"
HEALTH_OUTPUT="/tmp/prosody-health-check-output"
HEALTH_FAILURE_FILE="/tmp/prosody-health-check-fails"
CRITICAL_FAILURE_THRESHHOLD=3
HEALTH_FAIL_LOCK_FILE="/tmp/prosody-unhealthy-lock"

TRACEBACK_PATH="/var/lib/prosody/traceback.txt"
# wait up to 2 minutes for traceback file
TRACEBACK_WAIT_TIMEOUT=120

# TODO: check if correct
BUCKET="dump-logs-${ENVIRONMENT}"
BUCKET_NS="fr4eeztjonbe"


# check every 10 seconds for traceback file
TRACEBACK_SLEEP_INTERVAL=10

CURL_BIN="/usr/bin/curl"
if [[ -z "$OCI_BIN" ]]; then
    OCI_BIN="/usr/local/bin/oci"
fi

JSTAMP=$(date +%Y-%m-%d-%H%M)
JHOST=$(hostname -s)

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
                    if [[ "$PROSODY_PID" == "0" ]]; then
                        PROSODY_PID=
                    fi
                    if [ -n "$PROSODY_PID" ]; then
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

                # now check for traceback, if exists then copy it to OCI bucket
                if [ -e "$TRACEBACK_PATH" ]; then

                    TB_PATH="traceback_${JHOST}_${JSTAMP}.txt"
                    DUMP_PATH="https://objectstorage.${ORACLE_REGION}.oraclecloud.com/n/$BUCKET_NS/b/$BUCKET/o/$TB_PATH"

                    echo "Uploading $TB_PATH"
                    $OCI_BIN os object put --bucket-name "$BUCKET" --file "$TRACEBACK_PATH" --name "$TB_PATH" --region "$ORACLE_REGION"

                    echo -e "Prosody failure traceback available at: $DUMP_PATH"
                else
                    echo -e "Prosody failure traceback unavailable from $JHOST at $JSTAMP"
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
    flock -n "$fd" \
        && return 0 \
        || return 1
}

function eexit() {
    local error_str="$@"

    echo "$error_str"

    exit 1
}

function main () {
    echo "Starting...."
    lock "$PROGNAME" \
        || eexit "Only one instance of $PROGNAME can run at one time."

    run_check
    echo "end..."
}

main
