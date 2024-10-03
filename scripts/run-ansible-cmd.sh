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

[ -z "$BATCH_INVENTORY_FILE" ] && BATCH_INVENTORY_FILE="./batch-inventory"

if [ -f "$BATCH_INVENTORY_FILE" ]; then
    echo "## using existing inventory file $BATCH_INVENTORY_FILE"
else
    echo "## building inventory file $BATCH_INVENTORY_FILE"
    echo '[all]' > ./batch-inventory
    $LOCAL_PATH/node.py --role $ROLE --environment $ENVIRONMENT --oracle --oracle_only --region $ORACLE_REGION --batch > $BATCH_INVENTORY_FILE
fi

NODE_CMD="$*"
ansible -i ./batch-inventory all -a "$NODE_CMD" -u $ANSIBLE_SSH_USER --become --become-user root
