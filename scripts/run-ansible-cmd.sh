#!/bin/bash

LOCAL_PATH=$(dirname "${BASH_SOURCE[0]}")

if [ -z "$ENVIRONMENT" ]; then
    echo "## ERROR in run-ansible-cmd.sh ENVIRONMENT must be set"
    exit 2
fi

if [ -z "$ROLE" ]; then
    echo "## ERROR in run-ansible-cmd.sh ROLE must be set"
    exit 2
fi

if [ "$#" == "0" ]; then
        echo "Usage: $0 command with parameters"
        exit 1
fi

[ -z "$ORACLE_REGION" ] && ORACLE_REGION="all"

[ -z "$ANSIBLE_SSH_USER" ] && ANSIBLE_SSH_USER="$(whoami)"

[ -z "$BATCH_INVENTORY_FILE" ] && BATCH_INVENTORY_FILE="./ansible-cmd-batch.inventory"

if [ -f "$BATCH_INVENTORY_FILE" ]; then
    echo "## using existing inventory file $BATCH_INVENTORY_FILE"
else
    echo "## building inventory file $BATCH_INVENTORY_FILE"
    echo '[all]' > $BATCH_INVENTORY_FILE
    POOL_TYPE_PARAM=
    [ -n "$POOL_TYPE" ] && POOL_TYPE_PARAM="--pool_type $POOL_TYPE"
    $LOCAL_PATH/node.py --role $ROLE $POOL_TYPE_PARAM --environment $ENVIRONMENT --oracle --oracle_only --region $ORACLE_REGION --batch >> $BATCH_INVENTORY_FILE
    if [[ $? -ne 0 ]]; then
        echo "## ERROR in run-ansible-cmd.sh failed to build inventory file"
        exit 2
    fi
fi

NODE_CMD="$*"
echo "## Running command: $NODE_CMD"
ansible -i $BATCH_INVENTORY_FILE all -a "$NODE_CMD" -u $ANSIBLE_SSH_USER --become --become-user root
