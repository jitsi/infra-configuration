#!/bin/bash

PROGNAME=$(basename "$0")
readonly PROGNAME

LOCKFILE_DIR="/tmp"
readonly LOCKFILE_DIR

LOCK_FD="200"
readonly LOCK_FD

#only allow curl to run for this many seconds
HEALTH_CHECK_TIMEOUT=3

HEALTH_URL="http://localhost:5280/http-bind"
HEALTH_OUTPUT="/tmp/prosody-health-check-output"
HEALTH_FAILURE_FILE="/tmp/prosody-health-check-fails"
CRITICAL_FAILURE_THRESHHOLD=3
HEALTH_FAIL_LOCK_FILE="/tmp/prosody-unhealthy-lock"

CURL_BIN="/usr/bin/curl"

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

                /usr/local/bin/dump-prosody.sh
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
