#!/bin/bash
. /usr/local/bin/oracle_cache.sh

set -e
set -x

BUCKET="jvb-bucket-${ENVIRONMENT}"
$OCI_BIN os object get -bn $BUCKET --name vault-password --file /root/.vault-password
$OCI_BIN os object get -bn $BUCKET --name id_rsa_jitsi_deployment --file /root/.ssh/id_rsa
chmod 400 /root/.ssh/id_rsa

[ -z "$CLOUD_NAME" ] && CLOUD_NAME="$ENVIRONMENT-$ORACLE_REGION"
[ -z "$JIGASI_RELEASE_NUMBER" ] && JIGASI_RELEASE_NUMBER="0"

#  export DOMAIN="oracle.jitsi.net"
export MY_IP=`curl -s curl http://169.254.169.254/opc/v1/vnics/ | jq .[0].privateIp -r`
export MY_COMPONENT_ID="$ENVIRONMENT-jigasi-$(echo $MY_IP | awk -F. '{print $2"-"$3"-"$4}')"
export MY_HOSTNAME="$MY_COMPONENT_ID.$DOMAIN"
hostname $MY_HOSTNAME

grep $MY_HOSTNAME /etc/hosts || echo "$MY_IP    $MY_HOSTNAME" >> /etc/hosts

export DEPLOY_TAGS="all"

/usr/local/bin/configure-jigasi-local.sh >> /var/log/postinstall-ansible.log 2>&1
