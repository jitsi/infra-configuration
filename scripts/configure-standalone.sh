#!/bin/bash

# IF THE CURRENT DIRECTORY HAS stack-env.sh THEN INCLUDE IT
[ -e ./stack-env.sh ] && . ./stack-env.sh

if [ -z "$ENVIRONMENT" ]; then
  echo "No ENVIRONMENT found. Exiting..."
  exit 203
fi

[ -e ./sites/$ENVIRONMENT/stack-env.sh ] && . ./sites/$ENVIRONMENT/stack-env.sh

# e.g. ../all/bin/terraform/standalone
LOCAL_PATH=$(dirname "${BASH_SOURCE[0]}")

if [ -z "$ENVIRONMENT" ]; then
    echo "ENVIRONMENT not defined, exiting.."
    exit 2
fi
[ -z "$UNIQUE_ID" ] && UNIQUE_ID="$TEST_ID"
if [ -z "$UNIQUE_ID" ]; then
    echo "UNIQUE_ID not defined, exiting.."
    exit 2
fi

[ -z "$CLOUD_PROVIDER" ] && CLOUD_PROVIDER="oracle"
[ -z "$DNS_ZONE_DOMAIN_NAME" ] && DNS_ZONE_DOMAIN_NAME="jitsi.net"

if [[ "$CLOUD_PROVIDER" == "aws" ]]; then
    if [ -z "$CLOUD_NAME"]; then
        # assume dev cloud in us-west-2
        CLOUD_NAME="us-west-2-dev1"
    fi
    TEST_ID="$UNIQUE_ID" $LOCAL_PATH/create-app-standalone-stack.sh $1
    exit $?
fi

if [[ "$CLOUD_PROVIDER" == "oracle" ]]; then
    if [ -z "$ORACLE_REGION" ]; then
        echo "ORACLE_REGION not defined, exiting.."
        exit 2
    fi
    if [ -z "$DOMAIN" ]; then
        export DOMAIN="$UNIQUE_ID.$DNS_ZONE_DOMAIN_NAME"
        echo "DOMAIN not defined, assuming default value: $DOMAIN"
    fi

    $LOCAL_PATH/configure-standalone-oracle.sh $1
    exit $?
fi