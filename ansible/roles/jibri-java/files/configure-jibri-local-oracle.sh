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

# checkout_repos: clone the infra repos from the in-region git mirror when this
# instance booted with one, github otherwise (JIT-16092). Installed by the
# boot-git-mirror role, which every role shipping this script depends on.
. /opt/jitsi/boot/git-mirror-lib.sh || { echo "Missing /opt/jitsi/boot/git-mirror-lib.sh, cannot check out the infra repos"; exit 1; }

[ -z "$CLOUD_NAME" ] && CLOUD_NAME="${ENVIRONMENT}-${ORACLE_REGION}"

DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}

PLAYBOOK="configure-jibri-java-local-oracle.yml"


if [ -z "$INFRA_CONFIGURATION_REPO" ]; then
  echo "No INFRA_CONFIGURATION_REPO set, using default..."
  export INFRA_CONFIGURATION_REPO="https://github.com/jitsi/infra-configuration.git"
fi

if [ -z "$INFRA_CUSTOMIZATIONS_REPO" ]; then
  echo "No INFRA_CUSTOMIZATIONS_REPO set, using default..."
  export INFRA_CUSTOMIZATIONS_REPO="https://github.com/jitsi/infra-customizations.git"
fi

#if there's still no git branch set, assume main
[ -z "$GIT_BRANCH" ] && GIT_BRANCH="main"

if ! checkout_repos; then
  echo "Failed to check out the infra repos from any source"
  exit 1
fi

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

exit $RET