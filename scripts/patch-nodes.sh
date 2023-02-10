#!/bin/bash

echo "## starting patch-nodes.sh"

if [  -z "$1" ]
then
  ANSIBLE_SSH_USER=$(whoami)
  echo "## ansible SSH user is not defined. We use current user: $ANSIBLE_SSH_USER"
else
  ANSIBLE_SSH_USER=$1
  echo "## run ansible as $ANSIBLE_SSH_USER"
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

DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}

[ -z "$ROLE" ] && ROLE="ssh"
[ -z "$ORACLE_REGION" ] && ORACLE_REGION="all"

ANSIBLE_PLAYBOOK_FILE=${ANSIBLE_PLAYBOOK_FILE-"patch-nodes-default.yml"}
ANSIBLE_PLAYBOOK="$LOCAL_PATH/../ansible/$ANSIBLE_PLAYBOOK_FILE"

ANSIBLE_ROLES="${ANSIBLE_ROLES-"sshusers"}"

ANSIBLE_EXTRA_VARS="${ANSIBLE_EXTRA_VARS-""}"
if [ -n "$ANSIBLE_EXTRA_VARS" ]; then
  ANSIBLE_EXTRA_VARS="-e '$ANSIBLE_EXTRA_VARS'"
fi

if [[ "$ENVIRONMENT_LIST" == "ALL" ]]; then
    ALL_ENVIRONMENTS="true"
    ENVIRONMENT_LIST=$(ls $LOCAL_PATH/../sites/)
    echo "## applying $ANSIBLE_PLAYBOOK_FILE to nodes with role $ROLE in region $ORACLE_REGION with ansible roles '$ANSIBLE_ROLES' in ALL environments: $ENVIRONMENT_LIST"
else
    echo "## applying $ANSIBLE_PLAYBOOK_FILE to nodes with role $ROLE in region $ORACLE_REGION with ansible roles '$ANSIBLE_ROLES' in these environments: $ENVIRONMENT_LIST"
fi

RELEASE_PARAM=""
if [ -n "$RELEASE_NUMBER" ]; then 
    echo "## patch-nodes.sh: filtering on release $RELEASE_NUMBER"
    RELEASE_PARAM="--release ${RELEASE_NUMBER}"
fi

rm -rf ./batch-${ROLE}-${ORACLE_REGION}*.inventory

BASE_INVENTORY="./batch-${ROLE}-${ORACLE_REGION}.inventory"

if [[ "$ALL_ENVIRONMENTS" == "true" ]]; then
    echo "## building $ROLE inventory for all environments in region $ORACLE_REGION"
    $LOCAL_PATH/node.py --environment all --role $ROLE --region $ORACLE_REGION --oracle --batch --inventory $RELEASE_PARAM >> $BASE_INVENTORY
else
    for ENV in $ENVIRONMENT_LIST; do
        echo "## building $ROLE inventory for $ENV in region $ORACLE_REGION"
        $LOCAL_PATH/node.py --environment $ENV --role $ROLE --region $ORACLE_REGION --oracle --batch --inventory $RELEASE_PARAM >> $BASE_INVENTORY
    done
fi

LIVE_INVENTORY="./batch-${ROLE}-${ORACLE_REGION}-live.inventory"

SSH_FAILED_COUNT=0
if [[ "$SKIP_SSH_CONFIRMATION" == "true" ]]; then
    echo "## skipping ssh confirmation"
    cp $BASE_INVENTORY $LIVE_INVENTORY
else
    while IFS='' read -r LINE || [ -n "$LINE" ]; do
        IP=$(echo $LINE | awk '{ print $1 }')
        echo "## confirming ssh liveness of $IP"
        timeout 10 ssh -n -o StrictHostKeyChecking=no -F $LOCAL_PATH/../config/ssh.config $ANSIBLE_SSH_USER@$IP "uptime > /dev/null" && echo $LINE >> $LIVE_INVENTORY || SSH_FAILED_COUNT=$(($SSH_FAILED_COUNT+1))
    done < "${BASE_INVENTORY}"
fi

echo "## slicing live inventory into batches"
BATCH_SIZE=${BATCH_SIZE-"10"}

[ -d ./.batch ] && rm -rf .batch
mkdir .batch
split -l $BATCH_SIZE $LIVE_INVENTORY ".batch/${ROLE}-${ORACLE_REGION}-"

ANSIBLE_FAILURES=0

echo "## starting $ANSIBLE_PLAYBOOK batch runs"
for BATCH_INVENTORY in .batch/${ROLE}-${ORACLE_REGION}-*; do
    echo "[tag_shard_role_$ROLE]" > ./batch.inventory
    cat $BATCH_INVENTORY >> ./batch.inventory

    ansible-playbook $ANSIBLE_PLAYBOOK \
        -i ./batch.inventory \
        -e "ansible_ssh_user=$ANSIBLE_SSH_USER shard_role=$ROLE patch_ansible_roles=\"$ANSIBLE_ROLES\"" \
        $ANSIBLE_EXTRA_VARS --vault-password-file .vault-password.txt \
        --tags "$DEPLOY_TAGS"

    if [[ $? -gt 0 ]]; then
        echo "ERROR: Ansible batch failed for $BATCH_INVENTORY"
        ANSIBLE_FAILURES=$(($ANSIBLE_FAILURES+1))
    fi
done

FINAL_RET=0
if [[ $ANSIBLE_FAILURES -gt 0 ]]; then
    echo "## ERROR: $ANSIBLE_FAILURES ansible errors with at least 1 node"
    FINAL_RET=1
fi

if [[ $SSH_FAILED_COUNT -gt 0 ]]; then
    echo "## WARNING: $SSH_FAILED_COUNT nodes were skipped due to ssh failure"
    FINAL_RET=2
fi

exit $FINAL_RET