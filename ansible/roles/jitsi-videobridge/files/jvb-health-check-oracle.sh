#!/bin/bash

readonly PROGNAME=$(basename "$0")
readonly LOCKFILE_DIR=/tmp
readonly LOCK_FD=200

#PULL IN SHARD, ENVIRONMENT, INSTANCE_ID
. /usr/local/bin/oracle_cache.sh

#only allow curl to run for this many seconds
HEALTH_CHECK_TIMEOUT=30

HEALTH_URL="http://localhost:8080/about/health"
HEALTH_OUTPUT="/tmp/health-check-output"
HEALTH_FAILURE_FILE="/tmp/health-check-fails"
CRITICAL_FAILURE_THRESHOLD=3
HEALTH_FAIL_LOCK_FILE="/tmp/jvb-unhealthy-lock"
JVB_USER="jvb"
LOAD_THRESHOLD=100

#maximum number of seconds to wait before unhealthy bridge is terminated
SLEEP_MAX=$((3600 * 12))

#check every interval to see if bridge is done shutting down
SLEEP_INTERVAL=60

GRACEFUL_SHUTDOWN_FILE="/tmp/graceful-shutdown-output"

CURL_BIN="/usr/bin/curl"

function run_check() {

  $CURL_BIN --max-time $HEALTH_CHECK_TIMEOUT -f $HEALTH_URL >$HEALTH_OUTPUT 2>&1
  if [ $? -eq 0 ]; then
    echo "Basic health OK"
    BASIC_HEALTH_PASSED=true
  else
    echo "Basic health failed"
    BASIC_HEALTH_PASSED=false
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

  if $BASIC_HEALTH_PASSED; then
    [ -e $HEALTH_FAILURE_FILE ] && rm $HEALTH_FAILURE_FILE
  else
    if [ -e $HEALTH_FAILURE_FILE ]; then
      CHECK_COUNT=$(($(cat $HEALTH_FAILURE_FILE) + 1))
    else
      CHECK_COUNT=1
    fi

    echo $CHECK_COUNT >$HEALTH_FAILURE_FILE
    if [ $CHECK_COUNT -gt $CRITICAL_FAILURE_THRESHOLD ]; then

      #only dump memory and set unhealth once, then write to lock file and never do it again unless lock is cleared
      if [ ! -f $HEALTH_FAIL_LOCK_FILE ]; then
        echo 'Unhealthy' >$HEALTH_FAIL_LOCK_FILE

        echo "Dump pre-terminate stats for JVB"
        # this script is run from different users, e.g. jsidecar, ubuntu, root, and should not use sudo commands
        PRE_TERMINATE_STATS="/usr/local/bin/dump-pre-terminate-stats-jvb.sh"
        if [ -x "$PRE_TERMINATE_STATS" ]; then
            $PRE_TERMINATE_STATS
        fi

        #Begin graceful shutdown of JVB in a background process
        sudo /usr/share/jitsi-videobridge/graceful_shutdown.sh >$GRACEFUL_SHUTDOWN_FILE 2>&1 &

        #Dump all JVB logs to Object Storage, must do this as root to access all needed information
        sudo /usr/local/bin/dump-jvb.sh


        #only terminate instance if it's a JVB (not standalone)
        if [ "$SHARD_ROLE" == "JVB" ]; then
          #wait for our requisite time and then terminate ourselves
          #loop and check if process is running, then terminate after final countdown
          ST=0
          FINISHED=false
          while true; do
            sleep $SLEEP_INTERVAL
            ST=$(($ST + $SLEEP_INTERVAL))
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

              # shutdown consul service if it is running
              service consul stop

              sudo /usr/local/bin/terminate_instance.sh
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
  flock -n $fd &&
    return 0 ||
    return 1
}

function eexit() {
  local error_str="$@"
  echo $error_str
  exit 1
}

function main() {
  lock $PROGNAME ||
    eexit "Only one instance of $PROGNAME can run at one time."

  run_check
}

main
