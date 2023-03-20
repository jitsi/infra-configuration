#!/bin/bash
set -x

if [ -z "$ENVIRONMENT" ]; then
    echo "No ENVIRONMENT set, exiting"
    exit 2
fi

LOCAL_PATH=$(dirname "${BASH_SOURCE[0]}")

[ -e "$LOCAL_PATH/../sites/$ENVIRONMENT/stack-env.sh" ] && . "$LOCAL_PATH/../sites/$ENVIRONMENT/stack-env.sh"

[ -z "$VAULT_PASSWORD_FILE" ] && VAULT_PASSWORD_FILE="$LOCAL_PATH/../.vault-password.txt"

if [ -z "$ORACLE_REGION" ]; then
    echo "No ORACLE_REGION set, exiting"
    exit 2
fi

NOMAD_JOB_PATH="$LOCAL_PATH/../nomad"
NOMAD_DC="$ENVIRONMENT-$ORACLE_REGION"

[ -z "$CONFIG_VARS_FILE" ] && CONFIG_VARS_FILE="$LOCAL_PATH/../config/vars.yml"

WAVEFRONT_PROXY_VARIABLE="wavefront_proxy_host_by_cloud.$ENVIRONMENT-$ORACLE_REGION"
export NOMAD_VAR_wavefront_proxy_server="$(cat $CONFIG_VARS_FILE | yq eval .${WAVEFRONT_PROXY_VARIABLE} -)"
export NOMAD_VAR_environment="$ENVIRONMENT"
export NOMAD_VAR_octo_region="$ORACLE_REGION"

JOB_NAME="telegraf-$ENVIRONMENT"

sed -e "s/\[JOB_NAME\]/$JOB_NAME/" "$NOMAD_JOB_PATH/telegraf.hcl" | nomad job run -var="dc=$NOMAD_DC" -
