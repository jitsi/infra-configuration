#!/bin/bash

export BOOTSTRAP_DIRECTORY="/tmp/bootstrap"
export LOCAL_REPO_DIRECTORY="/opt/jitsi/bootstrap"

function checkout_repos() {
  [ -d $BOOTSTRAP_DIRECTORY/infra-configuration ] && rm -rf $BOOTSTRAP_DIRECTORY/infra-configuration
  [ -d $BOOTSTRAP_DIRECTORY/infra-customizations ] && rm -rf $BOOTSTRAP_DIRECTORY/infra-customizations

  if [ ! -n "$(grep "^github.com " ~/.ssh/known_hosts)" ]; then ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null; fi

  mkdir -p "$BOOTSTRAP_DIRECTORY"
  if [ -d "$LOCAL_REPO_DIRECTORY" ]; then
    echo "Found local repo copies in $LOCAL_REPO_DIRECTORY, using instead of clone"
    cp -a $LOCAL_REPO_DIRECTORY/infra-configuration $BOOTSTRAP_DIRECTORY
    cp -a $LOCAL_REPO_DIRECTORY/infra-customizations $BOOTSTRAP_DIRECTORY
    cd $BOOTSTRAP_DIRECTORY/infra-configuration
    git pull
    cd -
    cd $BOOTSTRAP_DIRECTORY/infra-customizations
    git pull
    cd -
  else
    echo "No local repos found, cloning directly from github"
    git clone $INFRA_CONFIGURATION_REPO $BOOTSTRAP_DIRECTORY/infra-configuration
    git clone $INFRA_CUSTOMIZATIONS_REPO $BOOTSTRAP_DIRECTORY/infra-customizations
  fi

  cd $BOOTSTRAP_DIRECTORY/infra-configuration
  git checkout $GIT_BRANCH
  git submodule update --init --recursive
  git show-ref heads/$GIT_BRANCH || git show-ref tags/$GIT_BRANCH
  cd -
  cd $BOOTSTRAP_DIRECTORY/infra-customizations
  git checkout $GIT_BRANCH
  git submodule update --init --recursive
  git show-ref heads/$GIT_BRANCH || git show-ref tags/$GIT_BRANCH
  cp -a $BOOTSTRAP_DIRECTORY/infra-customizations/* $BOOTSTRAP_DIRECTORY/infra-configuration
  cd -
}

set -x
#load the basics like $ENVIRONMENT, $SHARD_ROLE and $SHARD (if set)
. /usr/local/bin/oracle_cache.sh

#unless specified, run all tags
DEPLOY_TAGS=${ANSIBLE_TAGS-"common,hcv-haproxy-configure,consul-haproxy,consul-template"}

PLAYBOOK="configure-haproxy-local.yml"

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

checkout_repos

cd $BOOTSTRAP_DIRECTORY/infra-configuration
ansible-playbook -v \
    -i "127.0.0.1," \
    -c local \
    --tags "$DEPLOY_TAGS" \
    --extra-vars "hcv_environment=$ENVIRONMENT cloud_name=$CLOUD_NAME cloud_provider=oracle oracle_region=$ORACLE_REGION region=$ORACLE_REGION domain=$DOMAIN" \
    --vault-password-file=/root/.vault-password \
    ansible/$PLAYBOOK
RET=$?
cd -


exit $RET