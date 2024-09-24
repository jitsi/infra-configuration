#!/bin/bash

#only allow curl to run for this many seconds
HEALTH_CHECK_TIMEOUT=30

HEALTH_URL="http://localhost:8788/about/health"
STATS_URL="http://localhost:8788/about/stats"
HEALTH_OUTPUT="/tmp/health-check-output"
HEALTH_FAILURE_FILE="/tmp/health-check-fails"
CRITICAL_FAILURE_THRESHHOLD=3
HEALTH_FAIL_LOCK_FILE="/tmp/jigasi-unhealthy-lock"
GRACEFUL_SHUTDOWN_FILE="/tmp/graceful-shutdown-output"

JAVA_USER="jigasi"

#maximum number of seconds to wait before unhealthy bridge is terminated
SLEEP_MAX=$((3600*6))

#check every interval to see if bridge is done shutting down
SLEEP_INTERVAL=60

CURL_BIN="/usr/bin/curl"

. /usr/local/bin/oracle_cache.sh

$CURL_BIN --max-time $HEALTH_CHECK_TIMEOUT -f $HEALTH_URL > $HEALTH_OUTPUT 2>&1
if [ $? -eq 0 ]; then
    echo "Basic health OK"
    BASIC_HEALTH_PASSED=true
else
  echo "Basic health failed"
  BASIC_HEALTH_PASSED=false
fi

if [[ "$SHARD_ROLE" == "jigasi-transcriber" ]]; then
  echo "Extended health skipped for transcriber"
  EXTENDED_HEALTH_PASSED=true
else
  STATS=$($CURL_BIN --max-time $HEALTH_CHECK_TIMEOUT -f $STATS_URL 2>/dev/null)
  if [ $? -eq 0 ]; then
      STATS_JQ="$(echo $STATS | jq ".")"
      if [ $? -gt 0 ]; then
        echo "Stats did not parse as JSON: $STATS_JQ"
        echo "extended health failed"
        EXTENDED_HEALTH_PASSED=false
      else
        echo "Extended health OK"
        EXTENDED_HEALTH_PASSED=true
      fi
  else
    echo "Extended health failed, stats not available"
    EXTENDED_HEALTH_PASSED=false
  fi
fi

if $BASIC_HEALTH_PASSED && $EXTENDED_HEALTH_PASSED; then
    HEALTH_CHECK_VALUE=1
    [ -e $HEALTH_FAILURE_FILE ] && rm $HEALTH_FAILURE_FILE
else
    HEALTH_CHECK_VALUE=0
    if [ -e $HEALTH_FAILURE_FILE ]; then
      CHECK_COUNT=$(( $(cat $HEALTH_FAILURE_FILE) +  1))
    else
      CHECK_COUNT=1
    fi
	echo $CHECK_COUNT > $HEALTH_FAILURE_FILE
  if [ $CHECK_COUNT -gt $CRITICAL_FAILURE_THRESHHOLD ]; then

    #only dump memory and set unhealth once, then write to lock file and never do it again unless lock is cleared
    if [ ! -f $HEALTH_FAIL_LOCK_FILE ]; then
      echo 'Unhealthy' > $HEALTH_FAIL_LOCK_FILE
      #Begin graceful shutdown of Jigasi in a background process
      sudo /usr/share/jigasi/graceful_shutdown.sh > $GRACEFUL_SHUTDOWN_FILE 2>&1 &
      #Dump all Jigasi logs to S3, must do this as root to access all needed information
      sudo /usr/local/bin/dump-jigasi.sh

      #wait for our requisite time and then terminate ourselves
      #loop and check if process is running, then terminate after final countdown
      ST=0
      FINISHED=false
      while true; do
          echo "Jigasi still running, sleeping $SLEEP_INTERVAL"
          sleep $SLEEP_INTERVAL
          ST=$(($ST+$SLEEP_INTERVAL))
          #check for running Jigasi
          PID=$(/bin/systemctl show -p MainPID jigasi | cut -d '=' -f2)
          if [[ $PID > 0 ]]; then
          echo "Found running jigasi reported by systemd at PID $PID"
          #attempt to poke the process to determine if it's still alive
          sudo -u $JAVA_USER kill -0 $PID
          if [[ $? == 0 ]]; then
              #wait a bit more, unless our sleep interval is greater than the max
              if [[ $ST -ge $SLEEP_MAX ]]; then
              FINISHED=true
              fi
              #now we loop back up to the top of while true above, onless $FINISHED finishes below
          else
              #systemd reports a PID but process is missing, so we're done
              FINISHED=true
          fi
          else
          #Jigasi finished shutting down or no jigasi running, so finish up
          FINISHED=true
          fi
          if $FINISHED; then
          echo "Jigasi failed or pid not found, terminating instance"
          sudo /usr/local/bin/terminate_instance.sh
          fi
      done
      #we are probably going to be shut down any minute, but keep looping anyway?
    else
      echo "Health lock detected, shutdown process in progress, exiting"
    fi
  fi

fi

