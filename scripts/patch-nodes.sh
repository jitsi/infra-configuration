#!/bin/bash

#IF THE CURRENT DIRECTORY HAS stack-env.sh THEN INCLUDE IT
[ -e ./stack-env.sh ] && . ./stack-env.sh

echo "## starting patch-nodes.sh"

if [  -z "$1" ]
then
  ANSIBLE_SSH_USER=$(whoami)
  echo "Ansible SSH user is not defined. We use current user: $ANSIBLE_SSH_USER"
else
  ANSIBLE_SSH_USER=$1
  echo "Run ansible as $ANSIBLE_SSH_USER"
fi

if [ -z "$ENVIRONMENT" ]; then
  echo "## ERROR in patch-nodes.sh: ENVIRONMENT must be set"
  exit 2
fi

[ -z "$ROLE" ] && ROLE="ssh"
[ -z "$ORACLE_REGION" ] && ORACLE_REGION="all"

LOCAL_PATH=$(dirname "${BASH_SOURCE[0]}")
[ -e $LOCAL_PATH/../sites/$ENVIRONMENT/stack-env.sh ] && . $LOCAL_PATH/../sites/$ENVIRONMENT/stack-env.sh

if [ -z "$ANSIBLE_INVENTORY" ]; then 
  ANSIBLE_INVENTORY="./batch-${ROLE}-${ORACLE_REGION}.inventory"
  $LOCAL_PATH/node.py --environment $ENVIRONMENT --role $ROLE --region $ORACLE_REGION --oracle --batch --inventory > $ANSIBLE_INVENTORY
fi

DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}
ANSIBLE_PLAYBOOK_FILE=${ANSIBLE_PLAYBOOK_FILE-"patch-nodes-default.yml"}
ANSIBLE_PLAYBOOK="$LOCAL_PATH/../../infra-configuration/ansible/$ANSIBLE_PLAYBOOK_FILE"

BATCH_SIZE=${BATCH_SIZE-"10"}

set -x

[ -d ./.batch ] && rm -rf .batch
mkdir .batch
split -l $BATCH_SIZE $ANSIBLE_INVENTORY ".batch/${ROLE}-${ORACLE_REGION}-"

FAILED_COUNT=0
ANSIBLE_FAILURES=0

for BATCH_INVENTORY in .batch/${ROLE}-${ORACLE_REGION}-*; do
    echo "[tag_shard_role_$ROLE]" > ./batch.inventory
    if [[ "$SKIP_SSH_CONFIRMATION" == "true" ]]; then
        cat $BATCH_INVENTORY >> ./batch.inventory
    else
        for ip in $(cat $BATCH_INVENTORY | tail -n+1 | awk '{print $1}'); do
            timeout 10 ssh -o StrictHostKeyChecking=no -F $LOCAL_PATH/../config/ssh.config $ANSIBLE_SSH_USER@$ip "uptime > /dev/null" && echo $ip >> ./batch.inventory || FAILED_COUNT=$(($FAILED_COUNT+1))
        done
    fi

    LIVE_COUNT=$(cat ./batch.inventory | wc -l | awk '{print $1}')
    if [[ $LIVE_COUNT -gt 1 ]]; then

        ansible-playbook $ANSIBLE_PLAYBOOK \
            -i ./batch.inventory \
            -e "ansible_ssh_user=$ANSIBLE_SSH_USER hcv_environment=$ENVIRONMENT shard_role=$ROLE" \
            --vault-password-file .vault-password.txt \
            --tags "$DEPLOY_TAGS"

        if [[ $? -gt 0 ]]; then
            echo "ERROR: Ansible batch failed"
            ANSIBLE_FAILURES=$(($ANSIBLE_FAILURES+1))
        fi
    else
        echo "No live instances found in batch, skipping"
    fi
done

FINAL_RET=0
if [[ $ANSIBLE_FAILURES -gt 0 ]]; then
    echo "$ANSIBLE_FAILURES ansible errors with at least 1 node"
    FINAL_RET=1
fi

if [[ $FAILED_COUNT -gt 0 ]]; then
    echo "$FAILED_COUNT nodes were skipped due to ssh failure"
    FINAL_RET=2
fi

exit $FINAL_RET