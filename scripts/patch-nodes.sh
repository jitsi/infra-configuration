#!/bin/bash

# Patches nodes in the Jitsi environment with one or more ansible roles which
# can be entered as a space-delimited list into the ANSIBLE_ROLES environment
# variable. The ANSIBLE_PLAYBOOK_FILE playbook is applied to machines which can
# be found with node.py with the ROLE tag.
#
# A typical use case is to update ssh users across instances, so ANSIBLE_ROLES
# defaults to sshusers and ROLE defaults to ssh.
#
# ENVIRONMENT_LIST can be set to a space delimited list of environments or the
# special ALL case will apply the playbook to all directories in /sites
#
# For example, to patch all jumpboxes with the sshusers role:
# > ROLE="ssh" ANSIBLE_ROLES="sshusers" ENVIRONMENT_LIST="ALL" ./scripts/patch-nodes.sh

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
    ENVIRONMENT_LIST=$(ls $LOCAL_PATH/../sites/)
    echo -e "## applying $ANSIBLE_PLAYBOOK_FILE to nodes with role $ROLE in region $ORACLE_REGION with ansible roles '$ANSIBLE_ROLES' in ALL environments:\n$ENVIRONMENT_LIST"
else
    echo -e "## applying $ANSIBLE_PLAYBOOK_FILE to nodes with role $ROLE in region $ORACLE_REGION with ansible roles '$ANSIBLE_ROLES' in these environments:\n$ENVIRONMENT_LIST"
fi

RELEASE_PARAM=""
if [ -n "$RELEASE_NUMBER" ]; then 
    echo "## patch-nodes.sh: filtering on release $RELEASE_NUMBER"
    RELEASE_PARAM="--release ${RELEASE_NUMBER}"
fi

rm -rf ./batch-${ROLE}-${ORACLE_REGION}*.inventory

BASE_INVENTORY="./batch-${ROLE}-${ORACLE_REGION}.inventory"

for ENV in $ENVIRONMENT_LIST; do
    echo "## building $ROLE inventory for $ENV in region $ORACLE_REGION"
    $LOCAL_PATH/node.py --environment $ENV --role $ROLE --region $ORACLE_REGION --oracle --batch --inventory $RELEASE_PARAM >> $BASE_INVENTORY
done

LIVE_INVENTORY="./batch-${ROLE}-${ORACLE_REGION}-live.inventory"

SSH_FAILED_IPS=""
if [[ "$SKIP_SSH_CONFIRMATION" == "true" ]]; then
    echo "## skipping ssh confirmation"
    cp $BASE_INVENTORY $LIVE_INVENTORY
else
    while IFS='' read -r LINE || [ -n "$LINE" ]; do
        IP=$(echo $LINE | awk '{ print $1 }')
        echo "## confirming ssh liveness of $IP"
        timeout 20 ssh -n -o StrictHostKeyChecking=no -F $LOCAL_PATH/../config/ssh.config $ANSIBLE_SSH_USER@$IP "uptime > /dev/null" && echo $LINE >> $LIVE_INVENTORY || SSH_FAILED_IPS="$SSH_FAILED_IPS $IP"
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

FAILED_IP_COUNT=$(echo "$SSH_FAILED_IPS" | wc | awk '{ print $2 }') 
if [[ $FAILED_IP_COUNT -gt 0 ]]; then
    echo "## WARNING: $FAILED_IP_COUNT nodes were skipped due to ssh failure:$SSH_FAILED_IPS"
    FINAL_RET=2
fi

exit $FINAL_RET