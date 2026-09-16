#!/bin/bash

export BOOTSTRAP_DIRECTORY="/tmp/bootstrap"
export LOCAL_REPO_DIRECTORY="/opt/jitsi/bootstrap"

# checkout_repos: clone the infra repos from the in-region git mirror when this
# instance booted with one, github otherwise (JIT-16092). Installed by the
# boot-git-mirror role, which every role shipping this script depends on.
. /opt/jitsi/boot/git-mirror-lib.sh || { echo "Missing /opt/jitsi/boot/git-mirror-lib.sh, cannot check out the infra repos"; exit 1; }

set -x
#load the basics like $ENVIRONMENT, $SHARD_ROLE and $SHARD (if set)
. /usr/local/bin/oracle_cache.sh

#unless specified, run all tags
DEPLOY_TAGS=${ANSIBLE_TAGS-"common,hcv-haproxy-configure,consul-haproxy,consul-template"}

PLAYBOOK="configure-haproxy-local.yml"

if [ -z "$INFRA_CONFIGURATION_REPO" ]; then
  echo "No INFRA_CONFIGURATION_REPO set, using default..."
  export INFRA_CONFIGURATION_REPO="https://github.com/jitsi/infra-configuration.git"
fi

if [ -z "$INFRA_CUSTOMIZATIONS_REPO" ]; then
  echo "No INFRA_CUSTOMIZATIONS_REPO set, using default..."
  export INFRA_CUSTOMIZATIONS_REPO="https://github.com/jitsi/infra-customizations.git"
fi

# if there's still no git branch set, assume main
[ -z "$GIT_BRANCH" ] && GIT_BRANCH="main"

if ! checkout_repos; then
  echo "Failed to check out the infra repos from any source"
  exit 1
fi

cd $BOOTSTRAP_DIRECTORY/infra-configuration
ansible-playbook -v \
    -i "127.0.0.1," \
    -c local \
    --tags "$DEPLOY_TAGS" \
    --extra-vars "hcv_environment=$ENVIRONMENT cloud_name=$CLOUD_NAME cloud_provider=oracle oracle_region=$ORACLE_REGION region=$ORACLE_REGION" \
    --vault-password-file=/root/.vault-password \
    ansible/$PLAYBOOK
RET=$?
cd -


exit $RET