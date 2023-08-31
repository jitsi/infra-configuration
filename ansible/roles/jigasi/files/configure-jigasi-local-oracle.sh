#!/bin/bash -v
export BOOTSTRAP_DIRECTORY="/tmp/bootstrap"
export LOCAL_REPO_DIRECTORY="/opt/jitsi/bootstrap"

function checkout_repos() {
  [ -d $BOOTSTRAP_DIRECTORY/infra-configuration ] && rm -rf $BOOTSTRAP_DIRECTORY/infra-configuration
  [ -d $BOOTSTRAP_DIRECTORY/infra-customizations ] && rm -rf $BOOTSTRAP_DIRECTORY/infra-customizations

  if [ ! -n "$(grep "^github.com " ~/.ssh/known_hosts)" ]; then ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null; fi

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
  git checkout $GIT_BRANCH || echo "No infra-configuration branch $GIT_BRANCH found, using main"
  git submodule update --init --recursive
  git show-ref heads/$GIT_BRANCH || git show-ref tags/$GIT_BRANCH || echo "No branch or tag $GIT_BRANCH found, using main"
  cd -
  cd $BOOTSTRAP_DIRECTORY/infra-customizations
  git checkout $GIT_BRANCH || echo "No infra-customizations branch $GIT_BRANCH found, using main"
  git submodule update --init --recursive
  git show-ref heads/$GIT_BRANCH || git show-ref tags/$GIT_BRANCH || echo "No branch or tag $GIT_BRANCH found, using main"
  cp -a $BOOTSTRAP_DIRECTORY/infra-customizations/* $BOOTSTRAP_DIRECTORY/infra-configuration
  cd -
}

#make sure we exit early if we fail any step
set -e
set -x

# This configures an instance running jitsi-videobridge with the parameters given below. The machine should be running on an image with jitsi-videobridge already installed

#first load our local instance information from Oracle (or cache) (ENVIRONMENT, DOMAIN, SHARD)
. /usr/local/bin/oracle_cache.sh

[ -z "$CLOUD_NAME" ] && CLOUD_NAME="${ENVIRONMENT}-${ORACLE_REGION}"

[ -z "$JIGASI_RELEASE_NUMBER" ] && JIGASI_RELEASE_NUMBER="0"

if [ "$CONFIGURE_ONLY" == "true" ]; then
    JIGASI_CONFIGURE_ONLY_FLAG="true"
else
    JIGASI_CONFIGURE_ONLY_FLAG="false"
fi


PLAYBOOK="configure-jigasi-local-oracle.yml"
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
      --extra-vars "hcv_environment=$ENVIRONMENT" \
      --extra-vars "cloud_name=$CLOUD_NAME jigasi_shard_role=$SHARD_ROLE prosody_domain_name=$DOMAIN cloud_provider=oracle region=$ORACLE_REGION oracle_region=$ORACLE_REGION jigasi_release_number=$JIGASI_RELEASE_NUMBER" \
      -e "{oracle_instance_id: $INSTANCE_ID}" \
      -e "{autoscaler_group: $CUSTOM_AUTO_SCALE_GROUP}" \
      -e "{jigasi_consul_datacenter: $AWS_CLOUD_NAME}" \
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
    --extra-vars "hcv_environment=$ENVIRONMENT" \
    --extra-vars "cloud_name=$CLOUD_NAME jigasi_shard_role=$SHARD_ROLE prosody_domain_name=$DOMAIN cloud_provider=oracle region=$ORACLE_REGION oracle_region=$ORACLE_REGION jigasi_release_number=$JIGASI_RELEASE_NUMBER" \
    -e "{oracle_instance_id: $INSTANCE_ID}" \
    -e "{autoscaler_group: $CUSTOM_AUTO_SCALE_GROUP}" \
    -e "{jigasi_consul_datacenter: $AWS_CLOUD_NAME}" \
    -e "{jigasi_configure_only_flag: $JIGASI_CONFIGURE_ONLY_FLAG}" \
    ansible/$PLAYBOOK
    RET=$?
fi

exit $RET