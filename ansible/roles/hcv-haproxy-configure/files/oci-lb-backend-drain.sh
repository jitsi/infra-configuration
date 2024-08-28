#!/bin/bash
. /usr/local/bin/oracle_cache.sh
set +x
INSTANCE_JSON="$(curl -s curl http://169.254.169.254/opc/v1/instance)"
INSTANCE_POOL="$(echo $INSTANCE_JSON | jq -r '.instancePoolId')"
ORACLE_REGION="$(echo $INSTANCE_JSON | jq -r '.regionInfo.regionIdentifier')"

if [ -n "$1" ]; then
    LOGFILE=$1
fi

alias timestamp="date --utc +%Y-%m-%d_%H:%M:%S.Z"

def log_msg() {
  echo "$(timestamp) [$$] olbd: $1" | tee -a $LOGFILE
}

if [ -z "$INSTANCE_POOL" ]; then
  echo "no instance pool found"
  exit 1
fi

if [ -z "$ORACLE_REGION" ]; then
  echo "no oracle region found"
  exit 1
fi

[ -z "$DRAIN_STATE" ] && DRAIN_STATE="true"

# get instance pool details with oci cli
INSTANCE_POOL_DETAILS="$(oci compute-management instance-pool get --instance-pool-id $INSTANCE_POOL --region $ORACLE_REGION --auth instance_principal)"

# get instance pool load balancer backend set name
# LB_DETAILS looks like this:
# {
#     "backend-set-name": "HAProxyLBBS",
#     "id": "ocid1.loadbalancerattachment.oc1.phx.aaaaaaaaytbgcv7bbifwys2mccxncaizvd7ez5gff3mwn7aov7l4uh6fackq",
#     "instance-pool-id": "ocid1.instancepool.oc1.phx.aaaaaaaar4xjrv7q2b32k3nbuoqry2og7djv2x5wqbfop2t6vp24hr376uzq",
#     "lifecycle-state": "ATTACHED",
#     "load-balancer-id": "ocid1.loadbalancer.oc1.phx.aaaaaaaamuknai3sp4yvkc7r4gb73zcrsfnoa4d3khdanrnckimxstd4eheq",
#     "port": 80,
#     "vnic-selection": "PrimaryVnic"
#   }
LB_DETAILS="$(echo "$INSTANCE_POOL_DETAILS" | jq '.data."load-balancers"|first')"


BACKEND_SET_NAME="$(echo "$LB_DETAILS" | jq -r '."backend-set-name"')"
LB_ID="$(echo "$LB_DETAILS" | jq -r '."load-balancer-id"')"

if [ -z "$BACKEND_SET_NAME" ]; then
  log_msg "no backend set name found; exiting"
  exit 1
fi

if [ -z "$LB_ID" ]; then
  log_msg "no load balancer id found; exiting"
  exit 1
fi

MY_IP="$(curl -s curl http://169.254.169.254/opc/v1/vnics/ | jq -r .[0].privateIp)"
MY_PORT=80
log_msg "Setting instance $MY_IP to drain: $DRAIN_STATE in lb $LB_ID backend $BACKEND_SET_NAME"

# edit the backend set to drain the instance
WORK_REQUEST="$(oci lb backend update --load-balancer-id $LB_ID --backend-set-name $BACKEND_SET_NAME --backend-name "$MY_IP:$MY_PORT" --drain $DRAIN_STATE --weight 1 --backup false --offline false --auth instance_principal --region $ORACLE_REGION)"

WORK_REQUEST_TIMEOUT=300
WAITED=0
if [ $? -eq 0 ]; then
    log_msg "successfully queued drain operation"
    WORK_REQUEST_ID="$(echo "$WORK_REQUEST" | jq -r '."opc-work-request-id"')"
    STATE="QUEUED"
    # wait for the work request to complete
    while [[ "$STATE" == "ACCEPTED" || "$STATE" == "QUEUED" || "$STATE" == "IN_PROGRESS" ]]; do
        log_msg "waiting for work request to complete"
        WAITED=$((WAITED+5))
        if [[ $WAITED -gt $WORK_REQUEST_TIMEOUT ]]; then
            log_msg "bd: work request timed out"
            STATE="TIMEOUT"
        else
            sleep 5
            STATUS="$(oci lb work-request get --work-request-id $WORK_REQUEST_ID --auth instance_principal --region $ORACLE_REGION)"
            STATE="$(echo "$STATUS" | jq -r '.data."lifecycle-state"')"
        fi
    done
    if [[ "$STATE" == "SUCCEEDED" ]]; then
        log_msg "successfully updated instance state"
    else
        log_msg "failed to update instance state: $STATUS"
        exit 1
    fi
fi
