#!/bin/bash
set -x

# Enables calling the oci API withing the oracle instance
export OCI_CLI_AUTH=instance_principal

INSTANCE_DETAILS=$(curl -s curl http://169.254.169.254/opc/v1/instance/)

function build_cache(){
    counter=1
    build_cache_status=1

    # Defined tags live in a namespace starting with eghtjitsi or equal to 'jitsi'
    while [ $counter -le 10 ]; do
        TAGS=$(echo $INSTANCE_DETAILS |  jq '.definedTags | to_entries[] | select((.key | startswith("eghtjitsi")) or (.key == "jitsi")) | .value'|jq -s '.|add')
        if [[ $? == 0 ]] && [[ $TAGS != "" ]] && [[ $TAGS != "{}" ]]; then
            TAGS=$(echo $TAGS $(echo $INSTANCE_DETAILS |  jq '.freeformTags')  | jq -s '.|add')
            echo $TAGS > $CACHE_PATH
            build_cache_status=0
            break
        else
            sleep 2
            ((counter++))
        fi
    done

    return $build_cache_status
}

export INSTANCE_ID=`echo $INSTANCE_DETAILS | jq .id -r`
export ORACLE_REGION=`echo $INSTANCE_DETAILS | jq .canonicalRegionName -r`
export AVAILABILITY_DOMAIN=`echo $INSTANCE_DETAILS | jq .availabilityDomain -r`
export COMPARTMENT_ID=`echo $INSTANCE_DETAILS | jq .compartmentId -r`

#cache age is 1 week
AGE_MAX=$((86400*7))

export OCI_BIN="/usr/local/bin/oci"

export ENVIRONMENT_TAG="environment"
export ENVIRONMENT_TYPE_TAG="environment_type"
export DOMAIN_TAG="domain"
export NAME_TAG="Name"
export SHARD_TAG="shard"
export SHARD_ROLE_TAG="shard-role"
export GIT_BRANCH_TAG="git_branch"
export RELEASE_NUMBER_TAG="release_number"
export JIBRI_RELEASE_NUMBER_TAG="jibri_release_number"
export JVB_RELEASE_NUMBER_TAG="jvb_release_number"
export JIGASI_RELEASE_NUMBER_TAG="jigasi_release_number"
export XMPP_HOST_PUBLIC_IP_ADDRESS_TAG="xmpp_host_public_ip_address"
export AWS_CLOUD_NAME_TAG="aws_cloud_name"
export AWS_AUTO_SCALE_GROUP_TAG="aws_auto_scale_group"
export AUTOSCALER_SIDECAR_JVB_FLAG_TAG="autoscaler_sidecar_jvb_flag"
export JVB_POOL_MODE_TAG="jvb_pool_mode"
export INFRA_CONFIGURATION_REPO_TAG="configuration_repo"
export INFRA_CUSTOMIZATIONS_REPO_TAG="customizations_repo"

export CACHE_PATH="/tmp/oracle_cache-${INSTANCE_ID}"

BUILD_CACHE=false
if [ -e "$CACHE_PATH" ]; then
    FILE_AGE=$(date -r $CACHE_PATH +%s)
    NOW=$(date +%s)
    if [ $((NOW-FILE_AGE)) -gt $AGE_MAX ]; then
        #rebuild cache
        BUILD_CACHE=true
    else
        #don't rebuild cache
        BUILD_CACHE=false
    fi
else
    #build the cache
    BUILD_CACHE=true
fi

if $BUILD_CACHE; then
    #start building
    build_cache
    if [[ $? -eq 1 ]];then
        echo 'Instance tags not defined.Exit'
        exit 1
    fi
fi

export DOMAIN=$(cat $CACHE_PATH | jq -r --arg DOMAIN_TAG "$DOMAIN_TAG" ".[\"$DOMAIN_TAG\"]")
export ENVIRONMENT=$(cat $CACHE_PATH | jq -r --arg ENVIRONMENT_TAG "$ENVIRONMENT_TAG" ".[\"$ENVIRONMENT_TAG\"]")
export ENVIRONMENT_TYPE=$(cat $CACHE_PATH | jq -r --arg ENVIRONMENT_TYPE_TAG "$ENVIRONMENT_TYPE_TAG" ".[\"$ENVIRONMENT_TYPE_TAG\"]")
export SHARD=$(cat $CACHE_PATH | jq -r --arg SHARD_TAG "$SHARD_TAG" ".[\"$SHARD_TAG\"]")
export SHARD_ROLE=$(cat $CACHE_PATH | jq -r --arg SHARD_ROLE_TAG "$SHARD_ROLE_TAG" ".[\"$SHARD_ROLE_TAG\"]")
export RELEASE_NUMBER=$(cat $CACHE_PATH | jq -r --arg RELEASE_NUMBER_TAG "$RELEASE_NUMBER_TAG" ".[\"$RELEASE_NUMBER_TAG\"]")
export JIBRI_RELEASE_NUMBER=$(cat $CACHE_PATH | jq -r --arg JIBRI_RELEASE_NUMBER_TAG "$JIBRI_RELEASE_NUMBER_TAG" ".[\"$JIBRI_RELEASE_NUMBER_TAG\"]")
export JVB_RELEASE_NUMBER=$(cat $CACHE_PATH | jq -r --arg JVB_RELEASE_NUMBER_TAG "$JVB_RELEASE_NUMBER_TAG" ".[\"$JVB_RELEASE_NUMBER_TAG\"]")
export JIGASI_RELEASE_NUMBER=$(cat $CACHE_PATH | jq -r --arg JIGASI_RELEASE_NUMBER_TAG "$JIGASI_RELEASE_NUMBER_TAG" ".[\"$JIGASI_RELEASE_NUMBER_TAG\"]")
[ -z "$GIT_BRANCH" ] && export GIT_BRANCH=$(cat $CACHE_PATH | jq -r --arg GIT_BRANCH_TAG "$GIT_BRANCH_TAG" ".[\"$GIT_BRANCH_TAG\"]")
export XMPP_HOST_PUBLIC_IP_ADDRESS=$(cat $CACHE_PATH | jq -r --arg XMPP_HOST_PUBLIC_IP_ADDRESS_TAG "$XMPP_HOST_PUBLIC_IP_ADDRESS_TAG" ".[\"$XMPP_HOST_PUBLIC_IP_ADDRESS_TAG\"]")
export AWS_CLOUD_NAME=$(cat $CACHE_PATH | jq -r --arg AWS_CLOUD_NAME_TAG "$AWS_CLOUD_NAME_TAG" ".[\"$AWS_CLOUD_NAME_TAG\"]")
export AWS_AUTO_SCALE_GROUP=$(cat $CACHE_PATH | jq -r --arg AWS_AUTO_SCALE_GROUP_TAG "$AWS_AUTO_SCALE_GROUP_TAG" ".[\"$AWS_AUTO_SCALE_GROUP_TAG\"]")
export AUTOSCALER_SIDECAR_JVB_FLAG=$(cat $CACHE_PATH | jq -r --arg AUTOSCALER_SIDECAR_JVB_FLAG_TAG "$AUTOSCALER_SIDECAR_JVB_FLAG_TAG" ".[\"$AUTOSCALER_SIDECAR_JVB_FLAG_TAG\"]")
export JVB_POOL_MODE=$(cat $CACHE_PATH | jq -r --arg JVB_POOL_MODE_TAG "$JVB_POOL_MODE_TAG" ".[\"$JVB_POOL_MODE_TAG\"]")
export TAGGED_INFRA_CONFIGURATION_REPO=$(cat $CACHE_PATH | jq -r --arg INFRA_CONFIGURATION_REPO_TAG "$INFRA_CONFIGURATION_REPO_TAG" ".[\"$INFRA_CONFIGURATION_REPO_TAG\"]")
export TAGGED_INFRA_CUSTOMIZATIONS_REPO=$(cat $CACHE_PATH | jq -r --arg INFRA_CUSTOMIZATIONS_REPO "$INFRA_CUSTOMIZATIONS_REPO" ".[\"$INFRA_CUSTOMIZATIONS_REPO\"]")

export CUSTOM_AUTO_SCALE_GROUP=$(echo $INSTANCE_DETAILS |  jq -r ."freeformTags.group")

if [ "$TAGGED_INFRA_CONFIGURATION_REPO" != "null" ]; then
  export INFRA_CONFIGURATION_REPO="$TAGGED_INFRA_CONFIGURATION_REPO"
fi

if [ "$TAGGED_INFRA_CUSTOMIZATIONS_REPO" != "null" ]; then
  export INFRA_CUSTOMIZATIONS_REPO="$TAGGED_INFRA_CUSTOMIZATIONS_REPO"
fi

export CLOUD_NAME="${ENVIRONMENT}-${ORACLE_REGION}"

if [ "$XMPP_HOST_PUBLIC_IP_ADDRESS" == "null" ]; then
  export XMPP_HOST_PUBLIC_IP_ADDRESS=
fi

if [ "$AWS_AUTO_SCALE_GROUP" == "null" ]; then
  export AWS_AUTO_SCALE_GROUP=
fi

if [ "$AUTOSCALER_SIDECAR_JVB_FLAG" == "null" ]; then
  export AUTOSCALER_SIDECAR_JVB_FLAG=
fi

if [ "$JVB_POOL_MODE" == "null" ]; then
  export JVB_POOL_MODE=
fi