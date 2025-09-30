#!/usr/bin/env bash
set -x
unset SSH_USER

# IF THE CURRENT DIRECTORY HAS stack-env.sh THEN INCLUDE IT
[ -e ./stack-env.sh ] && . ./stack-env.sh


[ -z "$UNIQUE_ID" ] && UNIQUE_ID=""

if [ -z "$ENVIRONMENT" ]; then
    echo "No ENVIRONMENT found. Exiting..."
    exit 203
fi

[ -e ./sites/$ENVIRONMENT/stack-env.sh ] && . ./sites/$ENVIRONMENT/stack-env.sh

# e.g. ../../../infra-configuration/scripts/upgrade-standalone-oracle.sh
LOCAL_PATH=$(dirname "${BASH_SOURCE[0]}")

[ -e "./clouds/all.sh" ] && . ./clouds/all.sh
[ -e "./clouds/oracle.sh" ] && . ./clouds/oracle.sh

if [ -z "$ORACLE_REGION" ]; then
    echo "No ORACLE_REGION found. Exiting..."
    exit 203
fi

[ -z "$INFRA_CONFIGURATION_REPO" ] && INFRA_CONFIGURATION_REPO="$PRIVATE_CONFIGURATION_REPO"
[ -z "$INFRA_CUSTOMIZATIONS_REPO" ] && INFRA_CUSTOMIZATIONS_REPO="$PRIVATE_CUSTOMIZATIONS_REPO"

if [ -z "$INFRA_CONFIGURATION_REPO" ]; then
    echo "No INFRA_CONFIGURATION_REPO set, using default..."
    INFRA_CONFIGURATION_REPO="https://github.com/jitsi/infra-configuration.git"
fi

if [ -z "$INFRA_CUSTOMIZATIONS_REPO" ]; then
    echo "No INFRA_CUSTOMIZATIONS_REPO set, using default..."
    INFRA_CUSTOMIZATIONS_REPO="https://github.com/jitsi/infra-customizations.git"
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
[ -z "$SHARD_BASE" ] && SHARD_BASE="$ENVIRONMENT"

CLOUD_PROVIDER="oracle"
[ -z "$PRIVATE_IP" ] && PRIVATE_IP="$(dig $RESOURCE_NAME_ROOT-internal.$DNS_ZONE_NAME +short)"

if [ -z "$PRIVATE_IP" ]; then
    echo "No PRIVATE_IP set or found from name $RESOURCE_NAME_ROOT-internal.$DNS_ZONE_NAME.  Exiting..."
    exit 3
fi

# Use latest versions by default for upgrade
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

# Set default Prosody version handling
PROSODY_APT_FLAG=''
if [ -n "$PROSODY_FROM_URL" ]; then
    [ "$PROSODY_FROM_URL" == "true" ] && PROSODY_APT_FLAG="false"
    [ "$PROSODY_FROM_URL" == "false" ] && PROSODY_APT_FLAG="true"
    PROSODY_APT_FLAG="\"prosody_install_from_apt\":$PROSODY_APT_FLAG"
fi

# # Load vault credentials if available
# if [ -f "$LOCAL_PATH/vault-login.sh" ]; then
#      . $LOCAL_PATH/vault-login.sh
# set +x     
#      export VAULT_TOKEN="$(cat $HOME/.vault-token)"
# set -x
# fi

# Create upgrade results directory
mkdir -p upgrade-results

echo "Starting upgrade of Jitsi components on $RESOURCE_NAME_ROOT-internal.$DNS_ZONE_NAME ($PRIVATE_IP)"
echo "Components to upgrade: jitsi-meet, jicofo, jvb, prosody"
echo "Target versions: JVB=$JVB_VERSION, Jicofo=$JICOFO_VERSION, Meet=$JITSI_MEET_VERSION"

ansible-playbook -v $LOCAL_PATH/../ansible/update-standalone.yml -i "$PRIVATE_IP," \
--extra-vars "cloud_provider=$CLOUD_PROVIDER inventory_cloud_provider=$CLOUD_PROVIDER core_cloud_provider=$CLOUD_PROVIDER cloud_name=$CLOUD_NAME hcv_environment=$ENVIRONMENT hcv_domain=$DOMAIN environment_domain_name=$DOMAIN prosody_domain_name=$DOMAIN shard_name=$SHARD_BASE-$ORACLE_REGION-$UNIQUE_ID" \
-e "ansible_python_interpreter=/usr/bin/python" \
-e "jitsi_videobridge_deb_pkg_version=$JVB_VERSION" \
-e "jicofo_deb_pkg_version=$JICOFO_VERSION" \
-e "jitsi_meet_deb_pkg_version=$JITSI_MEET_VERSION" \
-e "{$PROSODY_APT_FLAG}" \
$([ -n "$PROSODY_VERSION" ] && echo "-e prosody_version=$PROSODY_VERSION") \
$([ -n "$PROSODY_PACKAGE_VERSION" ] && echo "-e prosody_package_version=$PROSODY_PACKAGE_VERSION") \
$([ -n "$PROSODY_URL_VERSION" ] && echo "-e prosody_url_version=$PROSODY_URL_VERSION") \
$([ -n "$PROSODY_PACKAGE_NAME" ] && echo "-e prosody_package_name=$PROSODY_PACKAGE_NAME") \
$([ -n "$JITSI_MEET_PROSODY_VERSION" ] && echo "-e jitsi_meet_prosody_deb_pkg_version=$JITSI_MEET_PROSODY_VERSION") \
$([ -n "$ORACLE_REGION" ] && echo "-e oracle_region=$ORACLE_REGION") \
-e "infra_configuration_repo=$INFRA_CONFIGURATION_REPO" \
-e "infra_customizations_repo=$INFRA_CUSTOMIZATIONS_REPO" \
-e "test_id=$UNIQUE_ID" \
-e "unique_id=$UNIQUE_ID" \
-e "ansible_ssh_user=$ANSIBLE_SSH_USER" \
--vault-password-file .vault-password.txt

UPGRADE_EXIT_CODE=$?

if [ $UPGRADE_EXIT_CODE -eq 0 ]; then
    echo "Upgrade completed successfully!"
    if [ -f "upgrade-results/instance_versions" ]; then
        echo "=== Upgraded Component Versions ==="
        cat upgrade-results/instance_versions
        echo "=================================="
    fi
else
    echo "Upgrade failed with exit code: $UPGRADE_EXIT_CODE"
fi

exit $UPGRADE_EXIT_CODE