#!/bin/bash

export BOOTSTRAP_DIRECTORY="/tmp/bootstrap"

function checkout_repos() {
  [ -d $BOOTSTRAP_DIRECTORY/infra-configuration ] && rm -rf $BOOTSTRAP_DIRECTORY/infra-configuration
  [ -d $BOOTSTRAP_DIRECTORY/infra-customizations ] && rm -rf $BOOTSTRAP_DIRECTORY/infra-customizations
  mkdir -p $BOOTSTRAP_DIRECTORY
  if [ ! -n "$(grep "^github.com " ~/.ssh/known_hosts)" ]; then ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null; fi

  git clone $INFRA_CONFIGURATION_REPO $BOOTSTRAP_DIRECTORY/infra-configuration
  git clone $INFRA_CUSTOMIZATIONS_REPO $BOOTSTRAP_DIRECTORY/infra-customizations
  cd $BOOTSTRAP_DIRECTORY/infra-configuration
  git checkout $GIT_BRANCH
  git submodule update --init --recursive
  git show-ref heads/$GIT_BRANCH || git show-ref tags/$GIT_BRANCH

  cd -
  cd $BOOTSTRAP_DIRECTORY/infra-customizations
  git checkout $GIT_BRANCH
  git submodule update --init --recursive
  git show-ref heads/$GIT_BRANCH  || git show-ref tags/$GIT_BRANCH
  cp -a $BOOTSTRAP_DIRECTORY/infra-customizations/* $BOOTSTRAP_DIRECTORY/infra-configuration
  cd -
}


set -x
#load the basics like $ENVIRONMENT, $SHARD_ROLE and $SHARD (if set)
. /usr/local/bin/oracle_cache.sh

#unless specified, run all tags
DEPLOY_TAGS=${ANSIBLE_TAGS-"common,hcv-haproxy-configure"}

PLAYBOOK="configure-haproxy-local.yml"

if [ -n "$INFRA_CONFIGURATION_REPO" ]; then
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
else
  # if there's still no git branch set, assume master
  [ -z "$GIT_BRANCH" ] && GIT_BRANCH="master"

  ansible-pull -v -U git@github.com:8x8Cloud/jitsi-video-infrastructure.git \
    -d /tmp/bootstrap --purge \
    -i \"127.0.0.1,\" \
    --vault-password-file=/root/.vault-password \
    --accept-host-key \
    -C "$GIT_BRANCH" \
    --tags "$DEPLOY_TAGS" \
    --extra-vars "hcv_environment=$ENVIRONMENT cloud_name=$CLOUD_NAME cloud_provider=oracle oracle_region=$ORACLE_REGION region=$ORACLE_REGION" \
    ansible/$PLAYBOOK
    RET=$?
fi

exit $RET