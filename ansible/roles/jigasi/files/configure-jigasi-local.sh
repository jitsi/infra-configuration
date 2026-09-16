#!/usr/bin/env bash

export BOOTSTRAP_DIRECTORY="/tmp/bootstrap"
export LOCAL_REPO_DIRECTORY="/opt/jitsi/bootstrap"

# checkout_repos: clone the infra repos from the in-region git mirror when this
# instance booted with one, github otherwise (JIT-16092). Installed by the
# boot-git-mirror role, which every role shipping this script depends on.
. /opt/jitsi/boot/git-mirror-lib.sh || { echo "Missing /opt/jitsi/boot/git-mirror-lib.sh, cannot check out the infra repos"; exit 1; }

. /usr/local/bin/aws_cache.sh

[ -z "$EC2_REGION" ] && EC2_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION

if [ "$CONFIGURE_ONLY" == "true" ]; then
    JIGASI_CONFIGURE_ONLY_FLAG="true"
else
    JIGASI_CONFIGURE_ONLY_FLAG="false"
fi


PLAYBOOK="configure-jigasi-local.yml"
DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}
export ANSIBLE_VAULT_PASSWORD_FILE=/root/.vault-password

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
    --extra-vars "cloud_name=$CLOUD_NAME hcv_environment=$ENVIRONMENT environment_domain_name=$DOMAIN prosody_domain_name=$DOMAIN jigasi_shard_role=$SHARD_ROLE" \
    -e "{jigasi_configure_only_flag: $JIGASI_CONFIGURE_ONLY_FLAG}" \
    --vault-password-file=/root/.vault-password \
    ansible/$PLAYBOOK
RET=$?
cd -

exit $RET