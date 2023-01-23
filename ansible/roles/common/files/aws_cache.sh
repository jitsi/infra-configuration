#!/bin/bash

function build_cache(){ 
    counter=1
    build_cache_status=1

    while [ $counter -le 10 ]; do
        export CURRENT_EC2_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
        export AWS_DEFAULT_REGION=$CURRENT_EC2_REGION

        TAGS=$($AWS_BIN ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}")
        TAG_LENGTH=$(echo $TAGS | jq '.Tags|length')
        if [[ $? == 0 ]] && [[ $TAG_LENGTH -gt 0 ]]; then
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

export EC2_INSTANCE_ID=$(ec2metadata --instance-id)

export AWS_BIN="/usr/local/bin/aws"

export ENVIRONMENT_TAG="environment"
export DOMAIN_TAG="domain"
export NAME_TAG="Name"
export SHARD_TAG="shard"
export SHARD_ROLE_TAG="shard-role"
export CLOUD_NAME_TAG="cloud_name"
export CLOUD_PROVIDER_TAG="cloud_provider"
export GIT_BRANCH_TAG="git_branch"
export RELEASE_NUMBER_TAG="release_number"
export ASG_TAG="aws:autoscaling:groupName"
export INFRA_CONFIGURATION_REPO_TAG="configuration_repo"
export INFRA_CUSTOMIZATIONS_REPO_TAG="customizations_repo"

CACHE_PATH="/tmp/aws_cache-${EC2_INSTANCE_ID}"

BUILD_CACHE=false
if [ -e "$CACHE_PATH" ]; then
    BUILD_CACHE=false
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

[ -z "$CLOUD_NAME" ] && export CLOUD_NAME=$(cat $CACHE_PATH | jq -r ".Tags[] | select(.Key == \"$CLOUD_NAME_TAG\") | .Value")
[ -z "$CLOUD_PROVIDER" ] && export CLOUD_PROVIDER=$(cat $CACHE_PATH | jq -r ".Tags[] | select(.Key == \"$CLOUD_PROVIDER_TAG\") | .Value")
export DOMAIN=$(cat $CACHE_PATH | jq -r ".Tags[] | select(.Key == \"$DOMAIN_TAG\") | .Value")
export ENVIRONMENT=$(cat $CACHE_PATH | jq -r ".Tags[] | select(.Key == \"$ENVIRONMENT_TAG\") | .Value")
export SHARD=$(cat $CACHE_PATH | jq -r ".Tags[] | select(.Key == \"$SHARD_TAG\") | .Value")
export SHARD_ROLE=$(cat $CACHE_PATH | jq -r ".Tags[] | select(.Key == \"$SHARD_ROLE_TAG\") | .Value")
export AWS_NAME=$(cat $CACHE_PATH | jq -r ".Tags[] | select(.Key == \"$NAME_TAG\") | .Value")
export AUTO_SCALE_GROUP=$(cat $CACHE_PATH | jq -r ".Tags[] | select(.Key == \"$ASG_TAG\") | .Value")
export RELEASE_NUMBER=$(cat $CACHE_PATH | jq -r ".Tags[] | select(.Key == \"$RELEASE_NUMBER_TAG\") | .Value")
export GIT_BRANCH=$(cat $CACHE_PATH | jq -r ".Tags[] | select(.Key == \"$GIT_BRANCH_TAG\") | .Value")
export TAGGED_INFRA_CONFIGURATION_REPO=$(cat $CACHE_PATH | jq -r ".Tags[] | select(.Key == \"$INFRA_CONFIGURATION_REPO_TAG\") | .Value")
export TAGGED_INFRA_CUSTOMIZATIONS_REPO=$(cat $CACHE_PATH | jq -r ".Tags[] | select(.Key == \"$INFRA_CUSTOMIZATIONS_REPO_TAG\") | .Value")

if [ "$TAGGED_INFRA_CONFIGURATION_REPO" != "null" ]; then
  export INFRA_CONFIGURATION_REPO="$TAGGED_INFRA_CONFIGURATION_REPO"
fi

if [ "$TAGGED_INFRA_CUSTOMIZATIONS_REPO" != "null" ]; then
  export INFRA_CUSTOMIZATIONS_REPO="$TAGGED_INFRA_CUSTOMIZATIONS_REPO"
fi
