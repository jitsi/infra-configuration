#!/usr/bin/env bash
unset ANSIBLE_SSH_USER

[ -e ./stack-env.sh ] && . ./stack-env.sh

usage() { echo "Usage: $0 [<username>]" 1>&2; }

usage

if [  -z "$1" ]
then
  ANSIBLE_SSH_USER=$(whoami)
  echo "Ansible SSH user is not defined. We use current user: $ANSIBLE_SSH_USER"
else
  ANSIBLE_SSH_USER=$1
  echo "Run ansible as $ANSIBLE_SSH_USER"
fi

DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}

if [ -z "$ANSIBLE_INVENTORY" ]; then
  ANSIBLE_INVENTORY="../all/bin/ec2.py"
fi

ansible-playbook --verbose ../../ansible/configure-firezone.yml --extra-vars "hcv_environment=$ENVIRONMENT"   -i $ANSIBLE_INVENTORY \
-e "ansible_ssh_user=$ANSIBLE_SSH_USER" \
--vault-password-file ../../.vault-password.txt \
--tags "$DEPLOY_TAGS"
