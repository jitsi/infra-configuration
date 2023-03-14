#!/bin/bash

if [ -z "$ENVIRONMENT" ]; then
    echo "No ENVIRONMENT set, exiting"
    exit 2
fi

LOCAL_PATH=$(dirname "${BASH_SOURCE[0]}")

[ -e "$LOCAL_PATH/../sites/$ENVIRONMENT/stack-env.sh" ] && . "$LOCAL_PATH/../sites/$ENVIRONMENT/stack-env.sh"

if [ -z "$ORACLE_REGION" ]; then
    echo "No ORACLE_REGION set, exiting"
    exit 2
fi

[ -z "$DOCKER_TAG" ] && DOCKER_TAG="unstable-$(date +%Y-%m-%d)"

NOMAD_JOB_PATH="$LOCAL_PATH/../nomad"
NOMAD_DC="$ENVIRONMENT-$ORACLE_REGION"


export NOMAD_VAR_domain="$DOMAIN"
export NOMAD_VAR_tag="$DOCKER_TAG"

sed -e "s/\[JOB_NAME\]/$DOMAIN/" "$NOMAD_JOB_PATH/standalone.hcl" | nomad job run -var="dc=$NOMAD_DC" -
