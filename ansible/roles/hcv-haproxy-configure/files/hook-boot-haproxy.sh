#!/bin/bash
set -e
set -x
#load the basics like $ENVIRONMENT, $SHARD_ROLE and $SHARD (if set)
. /usr/local/bin/aws_cache.sh

#s3 bucket where we get our credentials for access to git and key for encrypted ansible variables
S3_BUCKET="jitsi-bootstrap-assets"

#booting up in AWS so set our region to local
[ -z "$CURRENT_EC2_REGION" ] && CURRENT_EC2_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$CURRENT_EC2_REGION

#if there's still no git branch set, assume master
[ -z "$GIT_BRANCH" ] && GIT_BRANCH="master"

#ensure files are present for access to encrypted vault and private repository
[ -e "/root/.vault-password" ] || /usr/local/bin/aws s3 cp s3://$S3_BUCKET/vault-password /root/.vault-password
[ -e "/root/.ssh/id_rsa" ] || /usr/local/bin/aws s3 cp s3://$S3_BUCKET/id_rsa_jitsi_deployment /root/.ssh/id_rsa
chmod 400 /root/.ssh/id_rsa

#unless specified, run all tags
DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}

[ -z "$SHARD_ROLE" ] && SHARD_ROLE="haproxy"

PLAYBOOK="configure-haproxy-local.yml"
BARON_STICKY_ENABLED="false"

if [ "$SHARD_ROLE" == "baron-haproxy" ]; then
    PLAYBOOK="configure-baron-haproxy-local.yml"
    BARON_STICKY_ENABLED="true"
fi

#do all the heavy lifting
ansible-pull -v -U git@github.com:8x8Cloud/jitsi-video-infrastructure.git \
-d /tmp/bootstrap --purge \
-i \"127.0.0.1,\" \
--vault-password-file=/root/.vault-password \
--accept-host-key \
-C "$GIT_BRANCH" \
--tags "$DEPLOY_TAGS" \
--extra-vars "cloud_name=$CLOUD_NAME hcv_environment=$ENVIRONMENT prosody_domain_name=$DOMAIN" \
-e "{haproxy_sticky_enabled: $BARON_STICKY_ENABLED, haproxy_baron_enabled: $BARON_STICKY_ENABLED, haproxy_boot_flag: true}" \
ansible/$PLAYBOOK