#!/bin/bash
#set -x
set -e

#PRE-CREATED SQS QUEUE WITH TTR=0 FOR MULTI-WORKER RECEIPT OF LIFECYCLE MESSAGES
QUEUE_NAME="jvb-terminating"

#LOG RESULTS TO THIS PRE-CREATED SNS TOPIC
SNS_TOPIC_NAME="JVB-Termination-Log"

WS_ZONE_ID="ZJ6O8D5EJO64L"
WS_DOMAIN="jitsi.net"

WS_HOSTNAME="$(hostname|cut -d '.' -f1).$WS_DOMAIN"

#UNIQUE LIFCE CYCLE HOOK NAME
LIFECYCLE_HOOK_NAME="scale-down-gracefully"

#REQUIRE A HEARTBEAT EVERY 30 MINUTES
HEART_BEAT_VAL=1800

#DELAY AT MOST 6 hours = 21600 seconds
TERMINATION_DELAY_TIMEOUT=21600

#PRINT AND SEND DEBUG OUTPUT TO SNS
DEBUG="true"

#PATH TO THE HEALTH LOCK FILE THAT USES IN jvb-health-check.sh
#we use it for disable health check when autoscaling shutdown instance
HEALTH_FAIL_LOCK_FILE="/tmp/jvb-unhealthy-lock"

JVB_SERVICE_NAME=$(/usr/bin/dpkg -l jitsi-videobridge* | /bin/egrep ^.i | /usr/bin/awk '{print $2}')

#NOTHING EASY TO EDIT BEYOND HERE
. /usr/local/bin/aws_cache.sh

EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
EC2_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION

if [[ -z "$AUTO_SCALE_GROUP" || "$AUTO_SCALE_GROUP" == "null" ]]; then
    #not in an ASG, so no monitoring needed, terminating
    echo "Not in an autoscaling group, not being monitored"
    exit 255
fi

NOTIFICATION_HTTP=$(aws sqs get-queue-url --queue-name=$QUEUE_NAME | jq -r .QueueUrl)
ACCOUNT_NUMBER=$(echo $NOTIFICATION_HTTP | cut -d/ -f4)

ROLE_NAME=$(aws ec2 describe-instances --filters "Name=instance-id,Values=${EC2_INSTANCE_ID}" | jq -r .Reservations[0].Instances[0].IamInstanceProfile.Arn | cut -d/ -f2)
ROLE_ARN="arn:aws:iam::$ACCOUNT_NUMBER:role/$ROLE_NAME"

SNS_TOPIC_ARN="arn:aws:sns:$EC2_REGION:$ACCOUNT_NUMBER:$SNS_TOPIC_NAME"

NOTIFICATION_TARGET="arn:aws:sqs:$EC2_REGION:$ACCOUNT_NUMBER:$QUEUE_NAME"


# create sqs jvb-terminating
# create iam role jvb-terminating-queue-publish
aws autoscaling put-lifecycle-hook --lifecycle-hook-name "${LIFECYCLE_HOOK_NAME}" \
 --auto-scaling-group-name "${AUTO_SCALE_GROUP}" \
 --lifecycle-transition "autoscaling:EC2_INSTANCE_TERMINATING" \
 --role-arn "${ROLE_ARN}" \
 --notification-target-arn "${NOTIFICATION_TARGET}" \
 --heartbeat-timeout ${HEART_BEAT_VAL} --default-result 'CONTINUE'


# LifecycleActionToken from the test message for creating the hook is needed
# later when extending the timeout or for completing the shutdown

#aws autoscaling delete-lifecycle-hook \
# --lifecycle-hook-name "scale-down-gracefully" \
# --auto-scaling-group-name "${AUTO_SCALE_GROUP}"


MESSAGE="Starting up termination monitoring for JVB on instance $EC2_INSTANCE_ID SHARD $SHARD ASG $AUTO_SCALE_GROUP"
$DEBUG && aws sns publish --topic-arn=$SNS_TOPIC_ARN --message="$MESSAGE"

while true
do
    # timeout-visibility 10, so all instances will receive message instantly and
    # will have 10 secs to delete it
    # we will distinguish whether message is for us by instance-id in message
    MESSAGES=$(aws sqs receive-message --queue-url ${NOTIFICATION_HTTP})
    [ ! -z "$MESSAGES" ] && $DEBUG && echo "messages: ${MESSAGES}"
    i=0
    msg=`echo ${MESSAGES} | jq -r ".Messages[$i]"`
    while [ -n "$msg" ] && [ ! "$msg" = "null" ] ;do

        MSG_AUTO_SCALE_GROUP=$(echo $msg | jq -r ".Body" | jq -r ".AutoScalingGroupName")
        # should be ${AUTO_SCALE_GROUP}

        MSG_TRANSITION=$(echo $msg | jq -r ".Body" | jq -r ".LifecycleTransition")
        # should be autoscaling:EC2_INSTANCE_TERMINATING

        MSG_INSTANCE_ID=$(echo $msg | jq -r ".Body" | jq -r ".EC2InstanceId")
        # should be EC2_INSTANCE_ID

#        MESSAGE="JVB MESSAGE $MSG_INSTANCE_ID $MSG_TRANSITION $MSG_AUTO_SCALE_GROUP for JVB on instance $EC2_INSTANCE_ID SHARD $SHARD ASG $AUTO_SCALE_GROUP"
#        $DEBUG && aws sns publish --topic-arn=$SNS_TOPIC_ARN --message="$MESSAGE"


        EVENT_TYPE=$(echo $msg | jq -r ".Body" | jq -r ".Event")
        if [ "${EVENT_TYPE}" = "autoscaling:TEST_NOTIFICATION" ]; then
            #DELETE test message upon receipt
            RECEIPT_HANDLE_VALUE=$(echo $msg | jq -r ".ReceiptHandle")
            aws sqs delete-message \
              --queue-url ${NOTIFICATION_HTTP} \
              --receipt-handle "${RECEIPT_HANDLE_VALUE}"

            $DEBUG && echo "test message found, deleted"

        elif [ "${MSG_AUTO_SCALE_GROUP}" = "${AUTO_SCALE_GROUP}" ] && \
                [ "${MSG_TRANSITION}" = "autoscaling:EC2_INSTANCE_TERMINATING" ] && \
                [ "${MSG_INSTANCE_ID}" = "${EC2_INSTANCE_ID}" ]; then

            ACTION_TOKEN=$(echo $msg | jq -r ".Body" | jq -r ".LifecycleActionToken")
            RECEIPT_HANDLE_VALUE=$(echo $msg | jq -r ".ReceiptHandle")

            $DEBUG && echo "new message for us found"
            MESSAGE="Shutdown message matches for JVB TOKEN $ACTION_TOKEN HANDLE $RECEIPT_HANDLE_VALUE on instance $EC2_INSTANCE_ID SHARD $SHARD ASG $AUTO_SCALE_GROUP"
            $DEBUG && aws sns publish --topic-arn=$SNS_TOPIC_ARN --message="$MESSAGE"

            # delete message if it is for us
            aws sqs delete-message \
              --queue-url ${NOTIFICATION_HTTP} \
              --receipt-handle "${RECEIPT_HANDLE_VALUE}"

            # mark node as unhealthy for disabling health monitoring
            echo 'Unhealthy' > $HEALTH_FAIL_LOCK_FILE

            # take another heartbeat if necessary (another 30minutes or whatever is configured)
            # execute it a little bit earlier to make sure we don't miss it :)
            # execute it in the background, anyway aws will delete our machine
            HEART_BEAT_EXECUTION=$((HEART_BEAT_VAL-180))
            SLEEPTIME=0
            (while true; do
                MESSAGE="Waiting $HEART_BEAT_EXECUTION secs to check shutdown JVB for $SLEEPTIME on instance $EC2_INSTANCE_ID SHARD $SHARD ASG $AUTO_SCALE_GROUP"
                $DEBUG && aws sns publish --topic-arn=$SNS_TOPIC_ARN --message="$MESSAGE"

                sleep ${HEART_BEAT_EXECUTION}
                SLEEPTIME=$(($SLEEPTIME+$HEART_BEAT_EXECUTION))

                if [ $SLEEPTIME -gt $TERMINATION_DELAY_TIMEOUT ]; then
                    #LOG TIMEOUT TO SNS
                    MESSAGE="Timeout $SLEEPTIME > $TERMINATION_DELAY_TIMEOUT during graceful shutdown by JVB on instance $EC2_INSTANCE_ID SHARD $SHARD ASG $AUTO_SCALE_GROUP"
                    $DEBUG && aws sns publish --topic-arn=$SNS_TOPIC_ARN --message="$MESSAGE"
                    # time to terminate
                    aws autoscaling complete-lifecycle-action \
                     --lifecycle-hook-name "${LIFECYCLE_HOOK_NAME}" \
                     --auto-scaling-group-name "${AUTO_SCALE_GROUP}" \
                     --lifecycle-action-token "${ACTION_TOKEN}" \
                     --lifecycle-action-result "CONTINUE"

                else
                    #SEND A HEARTBEAT
                    aws autoscaling record-lifecycle-action-heartbeat \
                         --lifecycle-hook-name "${LIFECYCLE_HOOK_NAME}" \
                         --auto-scaling-group-name "${AUTO_SCALE_GROUP}" \
                         --lifecycle-action-token "${ACTION_TOKEN}"
                 fi
            done)&

            PID=$(/bin/systemctl show -p MainPID $JVB_SERVICE_NAME | cut -d '=' -f2)
            if [[ $PID > 0 ]]; then
                SHUTDOWN_OUTPUT=$(/usr/share/jitsi-videobridge/graceful_shutdown.sh 2>&1)
                SHUTDOWN_RESULT=$?
                if [ $SHUTDOWN_RESULT -eq 0 ]; then
                    #LOG SUCCESS TO SNS
                    MESSAGE="Successful graceful shutdown by JVB on instance $EC2_INSTANCE_ID SHARD $SHARD ASG $AUTO_SCALE_GROUP"
                    $DEBUG && aws sns publish --topic-arn=$SNS_TOPIC_ARN --message="$MESSAGE"
                else
                    #LOG ERROR TO SNS
                    MESSAGE="Error $SHUTDOWN_RESULT during graceful shutting down JVB on instance $EC2_INSTANCE_ID SHARD $SHARD ASG $AUTO_SCALE_GROUP: $SHUTDOWN_OUTPUT"
                    $DEBUG && aws sns publish --topic-arn=$SNS_TOPIC_ARN --message="$MESSAGE"

                fi
            else
                #LOG ERROR TO SNS
                MESSAGE="Error during graceful shutdown: No JVB found PID: $PID, JVB not running on instance $EC2_INSTANCE_ID SHARD $SHARD ASG $AUTO_SCALE_GROUP: $SHUTDOWN_OUTPUT"
                $DEBUG && aws sns publish --topic-arn=$SNS_TOPIC_ARN --message="$MESSAGE"
            fi
            # time to terminate either way
            # clean up the Route53 DNS
            cd /usr/share/jitsi-ddns-lambda
            IPV4_ADDR=$(curl http://169.254.169.254/latest/meta-data/public-ipv4)
            IPV6_ADDR=$(ip addr | grep inet6 | grep "scope global" | awk '{print $2}' | cut -d '/' -f1)
            node index.js update_by_info --action remove --instance_name $WS_HOSTNAME --zone_id $WS_ZONE_ID --ipv4_addr $IPV4_ADDR --ipv6_addr $IPV6_ADDR || true
            cd -

            echo "Clean up the Route53 DNS"
            # this script is run from different users, e.g. jsidecar, ubuntu, root, and should not use sudo commands
            CLEANUP_ROUTE53_DNS="/usr/local/bin/cleanup_route53_dns.sh"
            if [ -f "$CLEANUP_ROUTE53_DNS" ]; then
                $CLEANUP_ROUTE53_DNS
            fi

            # now send the signal to terminate
            aws autoscaling complete-lifecycle-action \
             --lifecycle-hook-name "${LIFECYCLE_HOOK_NAME}" \
             --auto-scaling-group-name "${AUTO_SCALE_GROUP}" \
             --lifecycle-action-token "${ACTION_TOKEN}" \
             --lifecycle-action-result "CONTINUE"
        fi

        i=$(($i+1))
        msg=`echo ${MESSAGES} | jq ".Messages[$i]"`

    done
    sleep 15

done

MESSAGE="Ending termination monitoring for JVB on instance $EC2_INSTANCE_ID SHARD $SHARD ASG $AUTO_SCALE_GROUP"
$DEBUG && aws sns publish --topic-arn=$SNS_TOPIC_ARN --message="$MESSAGE"
