#!/usr/bin/env bash

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
  git show-ref heads/$GIT_BRANCH

  cd -
  cd $BOOTSTRAP_DIRECTORY/infra-customizations
  git checkout $GIT_BRANCH
  git submodule update --init --recursive
  git show-ref heads/$GIT_BRANCH
  cp -a $BOOTSTRAP_DIRECTORY/infra-customizations/* $BOOTSTRAP_DIRECTORY/infra-configuration
  cd -
}

. /usr/local/bin/aws_cache.sh

[ -z "$EC2_REGION" ] && EC2_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION

if [ "$CONFIGURE_ONLY" == "true" ]; then
    JIGASI_CONFIGURE_ONLY_FLAG="true"
else
    JIGASI_CONFIGURE_ONLY_FLAG="false"
fi


PLAYBOOK="configure-jigasi-local.yml"
DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}
export ANSIBLE_VAULT_PASSWORD_FILE=/root/.vault-password

if [ -n "$INFRA_CONFIGURATION_REPO" ]; then
  # if there's still no git branch set, assume main
  [ -z "$GIT_BRANCH" ] && GIT_BRANCH="main"

  checkout_repos

  cd $BOOTSTRAP_DIRECTORY/infra-configuration
  ansible-playbook -v \
      -i "127.0.0.1," \
      -c local \
      --tags "$DEPLOY_TAGS" \
      --extra-vars "cloud_name=$CLOUD_NAME hcv_environment=$ENVIRONMENT environment_domain_name=$DOMAIN prosody_domain_name=$DOMAIN jigasi_shard_role=$SHARD_ROLE" \
      -e "{jigasi_configure_only_flag: $JIGASI_CONFIGURE_ONLY_FLAG}" \
      --vault-password-file=/root/.vault-password \
      ansible/$PLAYBOOK
  RET=$?
  cd -
else
  # if there's still no git branch set, assume master
  [ -z "$GIT_BRANCH" ] && GIT_BRANCH="master"

  ansible-pull -v -U git@github.com:8x8Cloud/jitsi-video-infrastructure.git -d /tmp/bootstrap \
    --purge -i "127.0.0.1," --vault-password-file=/root/.vault-password --accept-host-key -C "$GIT_BRANCH" \
    --tags "$DEPLOY_TAGS" \
    --extra-vars "cloud_name=$CLOUD_NAME hcv_environment=$ENVIRONMENT environment_domain_name=$DOMAIN prosody_domain_name=$DOMAIN jigasi_shard_role=$SHARD_ROLE" \
    -e "{jigasi_configure_only_flag: $JIGASI_CONFIGURE_ONLY_FLAG}" \
    ansible/$PLAYBOOK
    RET=$?
fi

exit $RET