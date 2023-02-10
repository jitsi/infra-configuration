#!/bin/bash

echo "## starting patch-nodes.sh"

if [  -z "$1" ]
then
  ANSIBLE_SSH_USER=$(whoami)
  echo "Ansible SSH user is not defined. We use current user: $ANSIBLE_SSH_USER"
else
  ANSIBLE_SSH_USER=$1
  echo "Run ansible as $ANSIBLE_SSH_USER"
fi

if [ -z "$ENVIRONMENT_LIST" ]; then
    if [ -z "$ENVIRONMENT" ]; then
        ENVIRONMENT_LIST=$ENVIRONMENT
    else
        echo "## ERROR in patch-nodes.sh: ENVIRONMENT or ENVIRONMENT_LIST must be set"
        exit 2
    fi
fi

LOCAL_PATH=$(dirname "${BASH_SOURCE[0]}")

if [[ "$ENVIRONMENT_LIST" == "ALL" ]]; then
    ENVIRONMENT_LIST=$(ls $LOCAL_PATH/../sites/)
    echo "## applying patch to ALL environments: $ENVIRONMENT_LIST"
else
    echo "## applying patch to these environments: $ENVIRONMENT_LIST"
fi

[ -z "$ROLE" ] && ROLE="ssh"
[ -z "$ORACLE_REGION" ] && ORACLE_REGION="all"

RELEASE_PARAM=""
if [ -n "$RELEASE_NUMBER" ]; then 
    echo "## patch-nodes.sh: filtering on release $RELEASE_NUMBER"
    RELEASE_PARAM="--release ${RELEASE_NUMBER}"
fi

rm -rf ./batch-${ROLE}-${ORACLE_REGION}*.inventory

for ENV in $ENVIRONMENT_LIST; do
  ANSIBLE_INVENTORY="./batch-${ROLE}-${ORACLE_REGION}-${ENV}.inventory"
  $LOCAL_PATH/node.py --environment $ENV --role $ROLE --region $ORACLE_REGION --oracle --batch --inventory $RELEASE_PARAM > $ANSIBLE_INVENTORY
done

DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}

ANSIBLE_PLAYBOOK_FILE=${ANSIBLE_PLAYBOOK_FILE-"patch-nodes-default.yml"}
ANSIBLE_PLAYBOOK="$LOCAL_PATH/../ansible/$ANSIBLE_PLAYBOOK_FILE"

ANSIBLE_ROLES="${ANSIBLE_ROLES-"sshusers"}"

ANSIBLE_EXTRA_VARS="${ANSIBLE_EXTRA_VARS-""}"
if [ -n "$ANSIBLE_EXTRA_VARS" ]; then
  ANSIBLE_EXTRA_VARS="-e '$ANSIBLE_EXTRA_VARS'"
fi

BATCH_SIZE=${BATCH_SIZE-"10"}

[ -d ./.batch ] && rm -rf .batch
mkdir .batch
for ENV in $ENVIRONMENT_LIST; do
    ANSIBLE_INVENTORY="./batch-${ROLE}-${ORACLE_REGION}-${ENV}.inventory"
    split -l $BATCH_SIZE $ANSIBLE_INVENTORY ".batch/${ROLE}-${ORACLE_REGION}-${ENV}-"
done

FAILED_COUNT=0
ANSIBLE_FAILURES=0

set -x

for ENV in $ENVIRONMENT_LIST; do
    for BATCH_INVENTORY in .batch/${ROLE}-${ORACLE_REGION}-${ENV}*; do
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
                -e "ansible_ssh_user=$ANSIBLE_SSH_USER hcv_environment=$ENV shard_role=$ROLE patch_ansible_roles=\"$ANSIBLE_ROLES\"" \
                $ANSIBLE_EXTRA_VARS --vault-password-file .vault-password.txt \
                --tags "$DEPLOY_TAGS"

            if [[ $? -gt 0 ]]; then
                echo "ERROR: Ansible batch failed for ${ENV}"
                ANSIBLE_FAILURES=$(($ANSIBLE_FAILURES+1))
            fi
        else
            echo "No live instances found in batch for ${ENV}, skipping"
        fi
    done
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