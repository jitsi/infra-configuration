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

if [ -z "$INFRA_CONFIGURATION_REPO" ]; then
  echo "No INFRA_CONFIGURATION_REPO set, using default..."
  export INFRA_CONFIGURATION_REPO="https://github.com/jitsi/infra-configuration.git"
fi

if [ -z "$INFRA_CUSTOMIZATIONS_REPO" ]; then
  echo "No INFRA_CUSTOMIZATIONS_REPO set, using default..."
  export INFRA_CUSTOMIZATIONS_REPO="https://github.com/jitsi/infra-customizations.git"
fi

PLAYBOOK="configure-haproxy-local.yml"

# if there's still no git branch set, assume main
[ -z "$GIT_BRANCH" ] && GIT_BRANCH="main"

checkout_repos

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