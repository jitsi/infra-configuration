#!/usr/bin/env bash

#load DOMAIN, ENVIRONMENT, SHARD variables
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

SHARD_NUMBER=$(echo $SHARD| rev | cut -d"-" -f1 | rev | tr -d '[:alpha:]')

DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}

[ -z "$CLOUD_PROVIDER" ] && CLOUD_PROVIDER="aws"

ansible-pull -v -U git@github.com:8x8Cloud/jitsi-video-infrastructure.git \
-d /tmp/bootstrap --purge \
-i \"127.0.0.1,\" \
--vault-password-file=/root/.vault-password \
--accept-host-key \
-C "$GIT_BRANCH" \
--tags "$DEPLOY_TAGS" \
--extra-vars "cloud_name=$CLOUD_NAME cloud_provider=$CLOUD_PROVIDER hcv_environment=$ENVIRONMENT prosody_domain_name=$DOMAIN shard_name=$SHARD jitsi_release_number=$RELEASE_NUMBER shard_number=$SHARD_NUMBER" \
ansible/configure-core-local.yml
