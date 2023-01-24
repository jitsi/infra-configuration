#!/usr/bin/env bash
set -x
unset SSH_USER

# IF THE CURRENT DIRECTORY HAS stack-env.sh THEN INCLUDE IT
[ -e ./stack-env.sh ] && . ./stack-env.sh


if [ -z "$ENVIRONMENT" ]; then
  echo "No ENVIRONMENT found. Exiting..."
  exit 203
fi

[ -e ./sites/$ENVIRONMENT/stack-env.sh ] && . ./sites/$ENVIRONMENT/stack-env.sh

# e.g. ../../../infra-configuration/scripts/configure-standalone-oracle.sh
LOCAL_PATH=$(dirname "${BASH_SOURCE[0]}")

[ -z "$UNIQUE_ID" ] && UNIQUE_ID="$TEST_ID"
[ -z "$UNIQUE_ID" ] && UNIQUE_ID="standalone"
[ -e "./clouds/oracle.sh" ] && . ./clouds/oracle.sh


if [ -z "$ORACLE_REGION" ]; then
  echo "No ORACLE_REGION found. Exiting..."
  exit 203
fi

if [  -z "$1" ]
then
    ANSIBLE_SSH_USER=$(whoami)
    echo "Ansible SSH user is not defined. We use current user: $ANSIBLE_SSH_USER"
else
    ANSIBLE_SSH_USER=$1
    echo "Run ansible as $ANSIBLE_SSH_USER"
fi

ORACLE_CLOUD_NAME="$ORACLE_REGION-$ENVIRONMENT-oracle"
[ -e "./clouds/${ORACLE_CLOUD_NAME}.sh" ] && . ./clouds/${ORACLE_CLOUD_NAME}.sh

CLOUD_NAME="$ENVIRONMENT-$ORACLE_REGION"

RESOURCE_NAME_ROOT="$ENVIRONMENT-$ORACLE_REGION-$UNIQUE_ID"

[ -z "$DNS_ZONE_NAME" ] && DNS_ZONE_NAME="$DEFAULT_DNS_ZONE_NAME"

# [ -z "$S3_PROFILE" ] && S3_PROFILE="oracle"
# [ -z "$S3_STATE_BUCKET" ] && S3_STATE_BUCKET="tf-state-$ENVIRONMENT"
# [ -z "$S3_ENDPOINT" ] && S3_ENDPOINT="https://fr4eeztjonbe.compat.objectstorage.$ORACLE_REGION.oraclecloud.com"
# [ -z "$S3_STATE_KEY" ] && S3_STATE_KEY="$ENVIRONMENT/standalone/$UNIQUE_ID/terraform.tfstate"

# TF_PATH="$LOCAL_PATH/terraform/standalone"
# CURRENT_PATH=$(pwd)

# cd $TF_PATH

# #The —reconfigure option disregards any existing configuration, preventing migration of any existing state
# terraform init \
#   -backend-config="bucket=$S3_STATE_BUCKET" \
#   -backend-config="key=$S3_STATE_KEY" \
#   -backend-config="region=$ORACLE_REGION" \
#   -backend-config="profile=$S3_PROFILE" \
#   -backend-config="endpoint=$S3_ENDPOINT" \
#   -reconfigure

# terraform state list

# cd $CURRENT_PATH
[ -z "$DATADOG_ENABLED" ] && DATADOG_ENABLED="false"
[ -z "$TELEGRAF_ENABLED" ] && TELEGRAF_ENABLED="false"
[ -z "$WF_PROXY_ENABLED" ] && WF_PROXY_ENABLED="false"
#Standalone JVB websocket port is 9090 no TLS, overriding default 443 for bridge-only nodes
[ -z "$JVB_WEBSOCKETS_PORT" ] && JVB_WEBSOCKETS_PORT=9090
[ -z "$JVB_WEBSOCKETS_SSL" ] && JVB_WEBSOCKETS_SSL="false"

#use the latest build of all debs by default
if [ -z "$JVB_VERSION" ]; then
    JVB_VERSION='*'
else
    [ "$JVB_VERSION" == "*" ] || echo $JVB_VERSION | grep -q -- -1$ || JVB_VERSION="${JVB_VERSION}-1"
fi

if [ -z "$JICOFO_VERSION" ]; then
    JICOFO_VERSION='*'
else
    [ "$JICOFO_VERSION" == "*" ] || echo $JICOFO_VERSION | grep -q "1\.0" || JICOFO_VERSION="1.0-${JICOFO_VERSION}-1"
    [ "$JICOFO_VERSION" == "*" ] || echo $JICOFO_VERSION | grep -q -- -1$ || JICOFO_VERSION="${JICOFO_VERSION}-1"
fi

if [ -z "$JITSI_MEET_VERSION" ]; then
    JITSI_MEET_VERSION='*'
else
    [ "$JITSI_MEET_VERSION" == "*" ] || echo $JITSI_MEET_VERSION | grep -q "1\.0" || JITSI_MEET_VERSION="1.0.${JITSI_MEET_VERSION}-1"
    [ "$JITSI_MEET_VERSION" == "*" ] || echo $JITSI_MEET_VERSION | grep -q -- -1$ || JITSI_MEET_VERSION="${JITSI_MEET_VERSION}-1"
fi


CLOUD_PROVIDER="oracle"
[ -z "$PRIVATE_IP" ] && PRIVATE_IP="$(dig $RESOURCE_NAME_ROOT-internal.$DNS_ZONE_NAME +short)"

if [ -z "$PRIVATE_IP" ]; then
    echo "No PRIVATE_IP set or found from name $RESOURCE_NAME_ROOT-internal.$DNS_ZONE_NAME.  Exiting..."
    exit 3
fi

DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}

PROSODY_APT_FLAG=''
if [ -n "$PROSODY_FROM_URL" ]; then
    [ "$PROSODY_FROM_URL" == "true" ] && PROSODY_APT_FLAG="false"
    [ "$PROSODY_FROM_URL" == "false" ] && PROSODY_APT_FLAG="true"
    PROSODY_APT_FLAG="\"prosody_install_from_apt\":$PROSODY_APT_FLAG"
fi

ansible-playbook $LOCAL_PATH/../ansible/configure-standalone.yml -i "$PRIVATE_IP," \
--extra-vars "cloud_provider=$CLOUD_PROVIDER inventory_cloud_provider=$CLOUD_PROVIDER core_cloud_provider=$CLOUD_PROVIDER cloud_name=$CLOUD_NAME hcv_environment=$ENVIRONMENT hcv_domain=$DOMAIN environment_domain_name=$DOMAIN prosody_domain_name=$DOMAIN" \
-e "ansible_python_interpreter=/usr/bin/python" \
-e "jitsi_videobridge_deb_pkg_version=$JVB_VERSION" \
-e "jicofo_deb_pkg_version=$JICOFO_VERSION" \
-e "jitsi_meet_deb_pkg_version=$JITSI_MEET_VERSION" \
-e "{\"standalone_telegraf_enabled\":$TELEGRAF_ENABLED}" \
-e "{\"wf_proxy_enabled\":$WF_PROXY_ENABLED}" \
-e "jvb_websockets_port=$JVB_WEBSOCKETS_PORT" \
-e "{\"jvb_enable_websockets_ssl\":$JVB_WEBSOCKETS_SSL}" \
-e "{$PROSODY_APT_FLAG}" \
$([ -n $PROSODY_VERSION ] && echo "-e prosody_version=$PROSODY_VERSION") \
$([ -n $PROSODY_PACKAGE_VERSION ] && echo "-e prosody_package_version=$PROSODY_PACKAGE_VERSION") \
$([ -n $PROSODY_URL_VERSION ] && echo "-e prosody_url_version=$PROSODY_URL_VERSION") \
$([ -n $PROSODY_PACKAGE_NAME ] && echo "-e prosody_package_name=$PROSODY_PACKAGE_NAME") \
$([ -n $PROSODY_ENABLE_TOKENS ] && echo "-e prosody_enable_tokens=$PROSODY_ENABLE_TOKENS") \
$([ -n $JITSI_MEET_PROSODY_VERSION ] && echo "-e jitsi_meet_prosody_deb_pkg_version=$JITSI_MEET_PROSODY_VERSION") \
$([ -n $ORACLE_REGION ] && echo "-e oracle_region=$ORACLE_REGION") \
-e "test_id=$UNIQUE_ID" \
-e "ansible_ssh_user=$ANSIBLE_SSH_USER" \
--vault-password-file .vault-password.txt \
--tags "$DEPLOY_TAGS"
exit $?