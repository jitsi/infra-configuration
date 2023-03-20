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

if [ -z "$SHARD" ]; then
    echo "No SHARD set, exiting"
    exit 2
fi

[ -z "$DOCKER_TAG" ] && DOCKER_TAG="unstable-$(date +%Y-%m-%d)"

NOMAD_JOB_PATH="$LOCAL_PATH/../nomad"
NOMAD_DC="$ENVIRONMENT-$ORACLE_REGION"

[ -z "$ENCRYPTED_JVB_CREDENTIALS_FILE" ] && ENCRYPTED_JVB_CREDENTIALS_FILE="$LOCAL_PATH/../ansible/secrets/jvb.yml"
[ -z "$ENCRYPTED_JIBRI_CREDENTIALS_FILE" ] && ENCRYPTED_JIBRI_CREDENTIALS_FILE="$LOCAL_PATH/../ansible/secrets/jibri.yml"
[ -z "$ENCRYPTED_JIGASI_CREDENTIALS_FILE" ] && ENCRYPTED_JIGASI_CREDENTIALS_FILE="$LOCAL_PATH/../ansible/secrets/jigasi.yml"
[ -z "$JICOFO_CREDENTIALS_FILE" ] && JICOFO_CREDENTIALS_FILE="$LOCAL_PATH/../sites/$ENVIRONMENT/vars.yml"

JVB_XMPP_PASSWORD_VARIABLE="jvb_xmpp_password"
JIBRI_XMPP_PASSWORD_VARIABLE="jibri_auth_password"
JIBRI_RECORDER_PASSWORD_VARIABLE="jibri_selenium_auth_password"
JIGASI_XMPP_PASSWORD_VARIABLE="jigasi_xmpp_password"
JICOFO_XMPP_PASSWORD_VARIABLE="prosody_focus_user_secret"

# ensure no output for ansible vault contents and fail if ansible-vault fails
set +x
set -e
set -o pipefail
export NOMAD_VAR_jvb_auth_password="$(ansible-vault view $ENCRYPTED_JVB_CREDENTIALS_FILE --vault-password $VAULT_PASSWORD_FILE | yq eval ".${JVB_XMPP_PASSWORD_VARIABLE}" -)"
export NOMAD_VAR_jibri_xmpp_password="$(ansible-vault view $ENCRYPTED_JIBRI_CREDENTIALS_FILE --vault-password $VAULT_PASSWORD_FILE | yq eval ".${JIBRI_XMPP_PASSWORD_VARIABLE}" -)"
export NOMAD_VAR_jibri_recorder_password="$(ansible-vault view $ENCRYPTED_JIBRI_CREDENTIALS_FILE --vault-password $VAULT_PASSWORD_FILE | yq eval ".${JIBRI_RECORDER_PASSWORD_VARIABLE}" -)"
export NOMAD_VAR_jigasi_xmpp_password="$(ansible-vault view $ENCRYPTED_JIGASI_CREDENTIALS_FILE --vault-password $VAULT_PASSWORD_FILE | yq eval ".${JIGASI_XMPP_PASSWORD_VARIABLE}" -)"

export NOMAD_VAR_jicofo_auth_password="$(cat $JICOFO_CREDENTIALS_FILE | yq eval .${JICOFO_XMPP_PASSWORD_VARIABLE} -)"
set -x

export NOMAD_VAR_environment="$ENVIRONMENT"
export NOMAD_VAR_domain="$DOMAIN"
export NOMAD_VAR_shard="$SHARD"
export NOMAD_VAR_octo_region="$ORACLE_REGION"
# [ -n "$SHARD_STATE" ] && export NOMAD_VAR_shard_state="$SHARD_STATE"
export NOMAD_VAR_release_number="$RELEASE_NUMBER"
export NOMAD_VAR_tag="$DOCKER_TAG"

sed -e "s/\[JOB_NAME\]/$SHARD/" "$NOMAD_JOB_PATH/shard.hcl" | nomad job run -var="dc=$NOMAD_DC" -
