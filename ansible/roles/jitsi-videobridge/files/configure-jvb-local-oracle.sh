#!/bin/bash -v

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

#make sure we exit early if we fail any step
set -e
# This configures an instance running jitsi-videobridge with the parameters given below. The machine should be running on an image with jitsi-videobridge already installed

#first load our local instance information from Oracle (or cache) (ENVIRONMENT, DOMAIN, SHARD)
. /usr/local/bin/oracle_cache.sh

#search for the git branch attached to this instance
[ -z "$GIT_BRANCH" ] && GIT_BRANCH=$($OCI_BIN compute instance get --instance-id $INSTANCE_ID | jq --arg GIT_BRANCH_TAG "$GIT_BRANCH_TAG" '.data["freeform-tags"][$GIT_BRANCH_TAG]' -r)

# default to shard mode for JVBs
[ -z "$JVB_POOL_MODE" ] && JVB_POOL_MODE="shard"

#if we get "null" back from the tags, then assume none
[ "$GIT_BRANCH" == "null" ] && GIT_BRANCH=

[ -z "$CLOUD_NAME" ] && CLOUD_NAME="${ENVIRONMENT}-${ORACLE_REGION}"

[ -z "$JVB_RELEASE_NUMBER" ] && JVB_RELEASE_NUMBER="0"


#by default don't restart JVB, should come up cleanly on first boot with all configuration set
JVB_RECONFIGURE_ON_CHANGES_FLAG="false"

if [ -z "$RESTART_JVB_ON_RECONFIGURATION" ]; then
    EXTRA_VARS=""
else
    JVB_RECONFIGURE_ON_CHANGES_FLAG="true"
fi


if [ "$CONFIGURE_ONLY" == "true" ]; then
    JVB_RECONFIGURE_ON_CHANGES_FLAG="false"
fi

DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}

if [ -z "$AUTOSCALER_SIDECAR_JVB_FLAG" ]; then
    AUTOSCALER_SIDECAR_JVB_FLAG="false"
fi

PLAYBOOK="configure-jvb-local-oracle.yml"

if [ -n "$INFRA_CONFIGURATION_REPO" ]; then
    #if there's still no git branch set, assume main
    [ -z "$GIT_BRANCH" ] && GIT_BRANCH="main"

  checkout_repos

  cd $BOOTSTRAP_DIRECTORY/infra-configuration
  ansible-playbook -v \
    -i "127.0.0.1," \
    -c local \
    --vault-password-file=/root/.vault-password \
    --tags "$DEPLOY_TAGS" \
    --extra-vars "cloud_name=$CLOUD_NAME cloud_provider=oracle hcv_environment=$ENVIRONMENT prosody_domain_name=$DOMAIN shard_name=$SHARD " \
    -e "{environment_type: $ENVIRONMENT_TYPE}" \
    -e "{jvb_custom_region: $ORACLE_REGION}" \
    -e "{oracle_region: $ORACLE_REGION}" \
    -e "{jvb_consul_datacenter: $AWS_CLOUD_NAME}" \
    -e "{jitsi_release_number: $RELEASE_NUMBER}" \
    -e "{release_number: $RELEASE_NUMBER}" \
    -e "{jvb_release_number: $JVB_RELEASE_NUMBER}" \
    -e "{xmpp_host_public_ip_address: $XMPP_HOST_PUBLIC_IP_ADDRESS}" \
    -e "{jvb_reconfigure_on_changes_flag: $JVB_RECONFIGURE_ON_CHANGES_FLAG}" \
    -e "{oracle_instance_id: $INSTANCE_ID}" \
    -e "{autoscaler_group: $CUSTOM_AUTO_SCALE_GROUP}" \
    -e "{autoscaler_sidecar_jvb_flag: $AUTOSCALER_SIDECAR_JVB_FLAG}" \
    -e "{jvb_pool_mode: $JVB_POOL_MODE}" \
    ansible/$PLAYBOOK
  RET=$?
  cd -
else
    #if there's still no git branch set, assume master
    [ -z "$GIT_BRANCH" ] && GIT_BRANCH="master"

    ansible-pull -v -U git@github.com:8x8Cloud/jitsi-video-infrastructure.git \
    -v \
    -d /tmp/bootstrap --purge \
    -i \"127.0.0.1,\" \
    --vault-password-file=/root/.vault-password \
    --accept-host-key \
    -C "$GIT_BRANCH" \
    --tags "$DEPLOY_TAGS" \
    --extra-vars "cloud_name=$CLOUD_NAME cloud_provider=oracle hcv_environment=$ENVIRONMENT prosody_domain_name=$DOMAIN shard_name=$SHARD " \
    -e "{environment_type: $ENVIRONMENT_TYPE}" \
    -e "{jvb_custom_region: $ORACLE_REGION}" \
    -e "{oracle_region: $ORACLE_REGION}" \
    -e "{jvb_consul_datacenter: $AWS_CLOUD_NAME}" \
    -e "{jitsi_release_number: $RELEASE_NUMBER}" \
    -e "{release_number: $RELEASE_NUMBER}" \
    -e "{jvb_release_number: $JVB_RELEASE_NUMBER}" \
    -e "{xmpp_host_public_ip_address: $XMPP_HOST_PUBLIC_IP_ADDRESS}" \
    -e "{jvb_reconfigure_on_changes_flag: $JVB_RECONFIGURE_ON_CHANGES_FLAG}" \
    -e "{oracle_instance_id: $INSTANCE_ID}" \
    -e "{autoscaler_group: $CUSTOM_AUTO_SCALE_GROUP}" \
    -e "{autoscaler_sidecar_jvb_flag: $AUTOSCALER_SIDECAR_JVB_FLAG}" \
    -e "{jvb_pool_mode: $JVB_POOL_MODE}" \
    ansible/$PLAYBOOK
    RET=$?
fi

exit $RET
