#!/bin/bash
set -x
#load the basics like $ENVIRONMENT, $SHARD_ROLE and $SHARD (if set)
. /usr/local/bin/oracle_cache.sh

#if there's still no git branch set, assume master
[ -z "$GIT_BRANCH" ] && GIT_BRANCH="master"

#unless specified, run all tags
DEPLOY_TAGS=${ANSIBLE_TAGS-"common,hcv-haproxy-configure"}

#do all the heavy lifting
ansible-pull -v -U git@github.com:8x8Cloud/jitsi-video-infrastructure.git \
-d /tmp/bootstrap --purge \
-i \"127.0.0.1,\" \
--vault-password-file=/root/.vault-password \
--accept-host-key \
-C "$GIT_BRANCH" \
--tags "$DEPLOY_TAGS" \
--extra-vars "hcv_environment=$ENVIRONMENT cloud_name=$CLOUD_NAME cloud_provider=oracle oracle_region=$ORACLE_REGION region=$ORACLE_REGION" \
ansible/configure-haproxy-local.yml
