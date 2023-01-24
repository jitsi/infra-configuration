#!/bin/bash

#only allow curl to run for this many seconds
HEALTH_CHECK_TIMEOUT=30

HEALTH_URL="http://localhost:2222/jibri/api/v1.0/health"
HEALTH_OUTPUT="/tmp/health-check-output"
HEALTH_FAILURE_FILE="/tmp/health-check-fails"
CRITICAL_FAILURE_THRESHHOLD=5
HEALTH_FAIL_LOCK_FILE="/tmp/jibri-unhealthy-lock"
GRACEFUL_SHUTDOWN_FILE="/tmp/graceful-shutdown-output"

JAVA_USER="jibri"

#maximum number of seconds to wait before unhealthy bridge is terminated
SLEEP_MAX=$((3600*12))

#check every interval to see if bridge is done shutting down
SLEEP_INTERVAL=60

CURL_BIN="/usr/bin/curl"
AWS_BIN="/usr/local/bin/aws"
PIDOF_BIN="/bin/pidof"

. /usr/local/bin/aws_cache.sh

EC2_REGION=$($CURL_BIN -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION

CLOUDWATCH_DIMENSIONS="InstanceId=$EC2_INSTANCE_ID"
CLOUDWATCH_EXPIRED_DIMENSIONS="Environment=$ENVIRONMENT"

HEALTH_JSON=$($CURL_BIN --max-time $HEALTH_CHECK_TIMEOUT -f $HEALTH_URL)
HEALTH_STATUS_RETURN=$?
echo $HEALTH_JSON > $HEALTH_OUTPUT
if [ $HEALTH_STATUS_RETURN -eq 0 ]; then
    echo "Curl health OK"
    HEALTH_STATUS=$(echo $HEALTH_JSON| jq -r ".status.health.healthStatus")
    if [[ "$HEALTH_STATUS" == "HEALTHY" ]]; then
        echo "Basic health passed"
        BASIC_HEALTH_PASSED=true

        # basic health passed, so check if jibri is expired, otherwise move on
        BUSY_STATUS=$(echo $HEALTH_JSON | jq -r ".status.busyStatus")
        if [[ "$BUSY_STATUS" == "EXPIRED" ]]; then
          # Jibri has expired, needs to be rebooted
          TELEGRAF_PID=$(pidof telegraf)
          if [ -n "$TELEGRAF_PID" ]; then
            echo "Will sleep for 60 seconds to give time for telegraf metrics to be written."
            sleep 60

            # TODO: replace the sleep with a working flush. We still see missing stats after sending USR1 as below:
            #echo "Flushing telegraf metric buffers"
            #sudo kill -USR1 $TELEGRAF_PID
          else
            echo "Telegraf daemon not found, no buffers flushed"
          fi
          echo "Jibri Expired, rebooting"
          sudo /sbin/shutdown -r now
        fi
        if [[ "$BUSY_STATUS" == "BUSY" ]]; then
          # Jibri is in use, check for ffmpeg
          echo "Jibri in use, checking ffmpeg"
          FFMPEG_PID=$($PIDOF_BIN ffmpeg)
          if [ -z "$FFMPEG_PID" ]; then
            echo "ffmpeg not found but jibri reports BUSY, checking chromedriver state"
            CHROMEDRIVER_PID=$($PIDOF_BIN chromedriver)
            if [ -n "$CHROMEDRIVER_PID" ]; then
              echo "ffmpeg not found but chromedriver still running at pid $CHROMEDRIVER_PID, marking jibri as unhealthy"
              BASIC_HEALTH_PASSED=false
            else
              echo "chromedriver not running, jibri must be finalizing"
            fi
          else
            echo "ffmpeg running"
          fi
        fi
    else
        if [[ $HEALTH_STATUS == "UNHEALTHY" ]]; then
            healthyDetail=$(echo $HEALTH_JSON | jq -r ".status.health.details")
            echo $healthyDetail > "/tmp/health-fail-detail"
        fi
        echo "Basic health failed"
        BASIC_HEALTH_PASSED=false
    fi
else
  echo "Curl health failed"
  BASIC_HEALTH_PASSED=false
fi

if $BASIC_HEALTH_PASSED; then
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
    PID=$(/bin/systemctl show -p MainPID jibri 2>/dev/null | cut -d= -f2)

    #only dump memory and set unhealth once, then write to lock file and never do it again unless lock is cleared
    if [ ! -f $HEALTH_FAIL_LOCK_FILE ]; then
      echo 'Unhealthy' > $HEALTH_FAIL_LOCK_FILE
      #Begin graceful shutdown of jibri in a background process
      /opt/jitsi/jibri/wait_graceful_shutdown.sh > $GRACEFUL_SHUTDOWN_FILE 2>&1 &
      #Dump all Jigasi logs to S3, must do this as root to access all needed information
      /usr/local/bin/dump-jibri.sh

      if [ -n "$AUTO_SCALE_GROUP" ]; then
        #Detach our instance from the autoscaling group so a new Jibri can replace us
        $AWS_BIN autoscaling detach-instances --instance-ids "$EC2_INSTANCE_ID" --auto-scaling-group-name "$AUTO_SCALE_GROUP" --no-should-decrement-desired-capacity

        #wait for our requisite time and then terminate ourselves
        #loop and check if process is running, then terminate after final countdown
        ST=0
        FINISHED=false

        while true; do
            sleep $SLEEP_INTERVAL
            ST=$(($ST+$SLEEP_INTERVAL))
            sudo -u $JAVA_USER kill -0 $PID
            if [[ $? == 0 ]]; then
            #check for running JVB
            #attempt to poke the process to determine if it's still alive
            sudo -u $JAVA_USER kill -0 $PID
            if [[ $? == 0 ]]; then
                #wait a bit more, unless our sleep interval is greater than the max
                if [[ $ST -ge $SLEEP_MAX ]]; then
                FINISHED=true
                fi
            else
                FINISHED=true
            fi
            else
            #JVB finished shutting down, so finish up
            FINISHED=true
            fi
            if $FINISHED; then
            $AWS_BIN ec2 terminate-instances --instance-ids "$EC2_INSTANCE_ID"
            fi
        done
        #we are probably going to be shut down any minute, but keep looping anyway?
      fi
    fi
  fi

fi

