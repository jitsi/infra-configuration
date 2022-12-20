#!/bin/bash -v
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

#if we get "null" back from the tags, then assume master
[ "$GIT_BRANCH" == "null" ] && GIT_BRANCH="master"

#if there's still no git branch set, assume master
[ -z "$GIT_BRANCH" ] && GIT_BRANCH="master"

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

ansible-pull -v -U git@github.com:8x8Cloud/jitsi-video-infrastructure.git \
-v \
-d /tmp/bootstrap --purge \
-i \"127.0.0.1,\" \
--vault-password-file=/root/.vault-password \
--accept-host-key \
-C "$GIT_BRANCH" \
--tags "$DEPLOY_TAGS" \
--extra-vars "cloud_name=$CLOUD_NAME cloud_provider=$CLOUD_PROVIDER hcv_environment=$ENVIRONMENT prosody_domain_name=$DOMAIN shard_name=$SHARD jitsi_release_number=$RELEASE_NUMBER" \
-e "{jvb_reconfigure_on_changes_flag: $JVB_RECONFIGURE_ON_CHANGES_FLAG}" \
ansible/configure-jvb-local.yml

#eventually if this is all successful, then notify other system components via jitsi-system-events
#TODO: actually do the above