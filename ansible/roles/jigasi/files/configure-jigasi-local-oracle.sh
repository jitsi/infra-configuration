#!/bin/bash -v
export BOOTSTRAP_DIRECTORY="/tmp/bootstrap"
export LOCAL_REPO_DIRECTORY="/opt/jitsi/bootstrap"

# checkout_repos: clone the infra repos from the in-region git mirror when this
# instance booted with one, github otherwise (JIT-16092). Installed by the
# boot-git-mirror role, which every role shipping this script depends on.
. /opt/jitsi/boot/git-mirror-lib.sh || { echo "Missing /opt/jitsi/boot/git-mirror-lib.sh, cannot check out the infra repos"; exit 1; }
# a branch that exists nowhere falls back to main, as this script always did
GIT_FALLBACK_BRANCH="main"

#make sure we exit early if we fail any step
set -e
set -x

# This configures an instance running jitsi-videobridge with the parameters given below. The machine should be running on an image with jitsi-videobridge already installed

#first load our local instance information from Oracle (or cache) (ENVIRONMENT, DOMAIN, SHARD)
. /usr/local/bin/oracle_cache.sh

[ -z "$CLOUD_NAME" ] && CLOUD_NAME="${ENVIRONMENT}-${ORACLE_REGION}"

[ -z "$JIGASI_RELEASE_NUMBER" ] && JIGASI_RELEASE_NUMBER="0"

if [ "$CONFIGURE_ONLY" == "true" ]; then
    JIGASI_CONFIGURE_ONLY_FLAG="true"
else
    JIGASI_CONFIGURE_ONLY_FLAG="false"
fi


PLAYBOOK="configure-jigasi-local-oracle.yml"
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
    --extra-vars "hcv_environment=$ENVIRONMENT" \
    --extra-vars "cloud_name=$CLOUD_NAME jigasi_shard_role=$SHARD_ROLE prosody_domain_name=$DOMAIN cloud_provider=oracle region=$ORACLE_REGION oracle_region=$ORACLE_REGION jigasi_release_number=$JIGASI_RELEASE_NUMBER" \
    -e "{oracle_instance_id: $INSTANCE_ID}" \
    -e "{autoscaler_group: $CUSTOM_AUTO_SCALE_GROUP}" \
    -e "{jigasi_consul_datacenter: $AWS_CLOUD_NAME}" \
    -e "{jigasi_configure_only_flag: $JIGASI_CONFIGURE_ONLY_FLAG}" \
    --vault-password-file=/root/.vault-password \
    ansible/$PLAYBOOK
RET=$?
cd -

exit $RET