#!/usr/bin/env bash

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


if [ "$CONFIGURE_ONLY" == "true" ]; then
    JIBRI_CONFIGURE_ONLY_FLAG="true"
else
    JIBRI_CONFIGURE_ONLY_FLAG="false"
fi

if [ "$SHARD_ROLE" == "sip-jibri" ]; then
    JIBRI_PJSUA_FLAG="true"
else
    JIBRI_PJSUA_FLAG="false"
fi

DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}

ansible-pull -v -U git@github.com:8x8Cloud/jitsi-video-infrastructure.git \
-d /tmp/bootstrap --purge \
-i \"127.0.0.1,\" \
--vault-password-file=/root/.vault-password \
--accept-host-key \
-C "$GIT_BRANCH" \
--tags "$DEPLOY_TAGS" \
--extra-vars "cloud_name=$CLOUD_NAME hcv_environment=$ENVIRONMENT environment_domain_name=$DOMAIN prosody_domain_name=$DOMAIN" \
-e "{jibri_configure_only_flag: $JIBRI_CONFIGURE_ONLY_FLAG, jibri_pjsua_flag: $JIBRI_PJSUA_FLAG, sip_jibri_group: $AUTO_SCALE_GROUP}" \
ansible/configure-jibri-java-local.yml
