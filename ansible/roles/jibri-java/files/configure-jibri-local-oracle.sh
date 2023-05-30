#!/usr/bin/env bash

. /usr/local/bin/oracle_cache.sh
[ -z "$CACHE_PATH" ] && CACHE_PATH=$(ls /tmp/oracle_cache-*)
export BOOTSTRAP_DIRECTORY="/tmp/bootstrap"
export LOCAL_REPO_DIRECTORY="/opt/jitsi/bootstrap"

#if we get "null" back from the tags, then assume master
[ "$GIT_BRANCH" == "null" ] && GIT_BRANCH=

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

VOLUME_ID=$(oci compute boot-volume-attachment list --all --region "$ORACLE_REGION" --instance-id "$INSTANCE_ID" --availability-domain "$AVAILABILITY_DOMAIN" --compartment-id "$COMPARTMENT_ID" | jq -r '.data[] | select(."lifecycle-state" == "ATTACHED") | ."boot-volume-id"')
if [ -z "$VOLUME_ID"  ] || [ "$VOLUME_ID" == "null" ]; then
  VOLUME_ID="undefined"
fi

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

[ -z "$CLOUD_NAME" ] && CLOUD_NAME="${ENVIRONMENT}-${ORACLE_REGION}"

DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}

PLAYBOOK="configure-jibri-java-local-oracle.yml"

if [ -n "$INFRA_CONFIGURATION_REPO" ]; then
  # if there's still no git branch set, assume main
  [ -z "$GIT_BRANCH" ] && GIT_BRANCH="main"

  checkout_repos

  cd $BOOTSTRAP_DIRECTORY/infra-configuration
  ansible-playbook -v \
      -i "127.0.0.1," \
      -c local \
      --tags "$DEPLOY_TAGS" \
      --extra-vars "cloud_name=$CLOUD_NAME hcv_environment=$ENVIRONMENT environment_domain_name=$DOMAIN prosody_domain_name=$DOMAIN" \
      -e "{oracle_region: $ORACLE_REGION}" \
      -e "{oracle_instance_id: $INSTANCE_ID}" \
      -e "{instance_volume_id: $VOLUME_ID}" \
      -e "{autoscaler_group: $CUSTOM_AUTO_SCALE_GROUP}" \
      -e "{sip_jibri_group: $CUSTOM_AUTO_SCALE_GROUP}" \
      -e "{jibri_consul_datacenter: $AWS_CLOUD_NAME}" \
      -e "{jibri_configure_only_flag: $JIBRI_CONFIGURE_ONLY_FLAG, jibri_pjsua_flag: $JIBRI_PJSUA_FLAG}" \
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
    --extra-vars "cloud_name=$CLOUD_NAME hcv_environment=$ENVIRONMENT environment_domain_name=$DOMAIN prosody_domain_name=$DOMAIN" \
    -e "{oracle_region: $ORACLE_REGION}" \
    -e "{oracle_instance_id: $INSTANCE_ID}" \
    -e "{instance_volume_id: $VOLUME_ID}" \
    -e "{autoscaler_group: $CUSTOM_AUTO_SCALE_GROUP}" \
    -e "{sip_jibri_group: $CUSTOM_AUTO_SCALE_GROUP}" \
    -e "{jibri_consul_datacenter: $AWS_CLOUD_NAME}" \
    -e "{jibri_configure_only_flag: $JIBRI_CONFIGURE_ONLY_FLAG, jibri_pjsua_flag: $JIBRI_PJSUA_FLAG}" \
    ansible/$PLAYBOOK
    RET=$?
fi

exit $RET