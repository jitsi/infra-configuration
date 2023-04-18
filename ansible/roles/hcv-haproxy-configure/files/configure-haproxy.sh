#!/bin/bash
set -e
set -x
#load the basics like $ENVIRONMENT, $SHARD_ROLE and $SHARD (if set)
. /usr/local/bin/aws_cache.sh

#s3 bucket where we get our credentials for access to git and key for encrypted ansible variables
S3_BUCKET="jitsi-bootstrap-assets"
GIT_BRANCH_TAG="git_branch"

#booting up in AWS so set our region to local
[ -z "$CURRENT_EC2_REGION" ] && CURRENT_EC2_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$CURRENT_EC2_REGION

#search for the git branch attached to this instance
[ -z "$GIT_BRANCH" ] && GIT_BRANCH=$($AWS_BIN ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}" "Name=key,Values=${GIT_BRANCH_TAG}" | jq .Tags[0].Value -r)

#if we get "null" back from the tags, then assume master
[ "$GIT_BRANCH" == "null" ] && GIT_BRANCH="master"

#if there's still no git branch set, assume master
[ -z "$GIT_BRANCH" ] && GIT_BRANCH="master"

#ensure files are present for access to encrypted vault and private repository
[ -e "/root/.vault-password" ] || /usr/local/bin/aws s3 cp s3://$S3_BUCKET/vault-password /root/.vault-password
[ -e "/root/.ssh/id_rsa" ] || /usr/local/bin/aws s3 cp s3://$S3_BUCKET/id_rsa_jitsi_deployment /root/.ssh/id_rsa
chmod 400 /root/.ssh/id_rsa

#unless specified, run all tags
DEPLOY_TAGS=${ANSIBLE_TAGS-"ec2_facts,common,hcv-haproxy-configure,consul-template"}

#do all the heavy lifting
ansible-pull -v -U git@github.com:8x8Cloud/jitsi-video-infrastructure.git \
-d /tmp/bootstrap --purge \
-i \"127.0.0.1,\" \
--vault-password-file=/root/.vault-password \
--accept-host-key \
-C "$GIT_BRANCH" \
--tags "$DEPLOY_TAGS" \
--extra-vars "cloud_name=$CLOUD_NAME hcv_environment=$ENVIRONMENT prosody_domain_name=$DOMAIN" \
ansible/configure-haproxy-local.yml