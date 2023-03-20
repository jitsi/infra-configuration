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

[ -z "$ENVIRONMENT_VARS_FILE" ] && ENVIRONMENT_VARS_FILE="$LOCAL_PATH/../sites/$ENVIRONMENT/vars.yml"

COLIBRI_PROXY_SECOND_OCTET_REGEXP_VARIABLE="jvb_colibri_proxy_second_octet_regexp"
COLIBRI_PROXY_THIRD_OCTET_REGEXP_VARIABLE="jvb_colibri_proxy_third_octet_regexp"
COLIBRI_PROXY_FOURTH_OCTET_REGEXP_VARIABLE="jvb_colibri_proxy_fourth_octet_regexp"

COLIBRI_PROXY_SECOND_OCTET_REGEXP="$(cat $ENVIRONMENT_VARS_FILE | yq eval .${COLIBRI_PROXY_SECOND_OCTET_REGEXP_VARIABLE} -)"
COLIBRI_PROXY_THIRD_OCTET_REGEXP="$(cat $ENVIRONMENT_VARS_FILE | yq eval .${COLIBRI_PROXY_THIRD_OCTET_REGEXP_VARIABLE} -)"
COLIBRI_PROXY_FOURTH_OCTET_REGEXP="$(cat $ENVIRONMENT_VARS_FILE | yq eval .${COLIBRI_PROXY_FOURTH_OCTET_REGEXP_VARIABLE} -)"

if [ "$COLIBRI_PROXY_SECOND_OCTET_REGEXP" != "null" ]; then
    export NOMAD_VAR_colibri_proxy_second_octet_regexp="$COLIBRI_PROXY_SECOND_OCTET_REGEXP"
fi
if [ "$COLIBRI_PROXY_THIRD_OCTET_REGEXP" != "null" ]; then
    export NOMAD_VAR_colibri_proxy_third_octet_regexp="$COLIBRI_PROXY_THIRD_OCTET_REGEXP"
fi
if [ "$COLIBRI_PROXY_FOURTH_OCTET_REGEXP" != "null" ]; then
    export NOMAD_VAR_colibri_proxy_fourth_octet_regexp="$COLIBRI_PROXY_FOURTH_OCTET_REGEXP"
fi
export NOMAD_VAR_environment="$ENVIRONMENT"
export NOMAD_VAR_domain="$DOMAIN"
export NOMAD_VAR_octo_region="$ORACLE_REGION"

JOB_NAME="colibri-proxy-$ENVIRONMENT"

sed -e "s/\[JOB_NAME\]/$JOB_NAME/" "$NOMAD_JOB_PATH/colibri-proxy.hcl" | nomad job run -var="dc=$NOMAD_DC" -
