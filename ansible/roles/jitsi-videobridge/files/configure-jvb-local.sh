#!/bin/bash -v



export BOOTSTRAP_DIRECTORY="/tmp/bootstrap"
export LOCAL_REPO_DIRECTORY="/opt/jitsi/bootstrap"

# checkout_repos: clone the infra repos from the in-region git mirror when this
# instance booted with one, github otherwise (JIT-16092). Installed by the
# boot-git-mirror role, which every role shipping this script depends on.
. /opt/jitsi/boot/git-mirror-lib.sh || { echo "Missing /opt/jitsi/boot/git-mirror-lib.sh, cannot check out the infra repos"; exit 1; }

#make sure we exit early if we fail any step
set -e
# This configures an instance running jitsi-videobridge with the parameters given below. The machine should be running on an image with jitsi-videobridge already installed

#first load our local instance information from AWS (or cache) (ENVIRONMENT, DOMAIN, SHARD)
. /usr/local/bin/aws_cache.sh

GIT_BRANCH_TAG="git_branch"

[ -z "$EC2_REGION" ] && EC2_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION

#search for the git branch attached to this instance
[ -z "$GIT_BRANCH" ] && GIT_BRANCH=$($AWS_BIN ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}" "Name=key,Values=${GIT_BRANCH_TAG}" | jq .Tags[0].Value -r)

#if we get "null" back from the tags, then assume blank
[ "$GIT_BRANCH" == "null" ] && GIT_BRANCH=

#by default don't restart JVB, should come up cleanly on first boot with all configuration set
JVB_RECONFIGURE_ON_CHANGES_FLAG="false"

if [ -z "$RESTART_JVB_ON_RECONFIGURATION" ]; then
    EXTRA_VARS=""
else
    JVB_RECONFIGURE_ON_CHANGES_FLAG="true"
fi


if [ "$CONFIGURE_ONLY" == "true" ]; then
    JVB_RECONFIGURE_ON_CHANGES_FLAG="false"
fi

[ -z "$CLOUD_PROVIDER" ] && CLOUD_PROVIDER="aws"

DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}
PLAYBOOK="configure-jvb-local.yml"

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
    --extra-vars "cloud_name=$CLOUD_NAME cloud_provider=$CLOUD_PROVIDER hcv_environment=$ENVIRONMENT environment_domain_name=$DOMAIN prosody_domain_name=$DOMAIN shard_name=$SHARD jitsi_release_number=$RELEASE_NUMBER" \
    -e "{jvb_reconfigure_on_changes_flag: $JVB_RECONFIGURE_ON_CHANGES_FLAG}" \
    --vault-password-file=/root/.vault-password \
    ansible/$PLAYBOOK
RET=$?
cd -

exit $RET
