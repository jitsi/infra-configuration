#!/usr/bin/env bash
. /usr/local/bin/oracle_cache.sh
# Enables calling the oci API withing the oracle instance
export OCI_CLI_AUTH=instance_principal

export OCI_BIN="/usr/local/bin/oci"

INSTANCE_METADATA=`curl -s http://169.254.169.254/opc/v1/instance/`

if [ -z "$PUBLIC_DOMAIN" ]; then
    DOMAIN=$XMPP_DOMAIN
else
    DOMAIN=$PUBLIC_DOMAIN
fi

if [ -z "$DOMAIN" ]; then
    DOMAIN="jitsi.net"
fi

MY_IP=`curl -s curl http://169.254.169.254/opc/v1/vnics/ | jq .[0].privateIp -r`
MY_COMPONENT_ID="coturn-$(echo $MY_IP | awk -F. '{print $4}')"
#TODO in AWS this uses EC2_REGION instead of ORACLE_REGION
MY_HOSTNAME="${ENVIRONMENT}-${ORACLE_REGION}-${MY_COMPONENT_ID}.$DOMAIN"

hostname $MY_HOSTNAME

#make sure we have an entry in /etc/hosts for this IP/hostname combination, add it if missing
grep $MY_HOSTNAME /etc/hosts || echo "$MY_IP    $MY_HOSTNAME" >> /etc/hosts

#set Name tag by getting current freeform-tags/defined-tags and appending the name tag
DEFINED_TAGS_NAMESPACE="jitsi"
NEW_DEFINED_TAGS=`echo $INSTANCE_METADATA | jq --arg MY_HOSTNAME "$MY_HOSTNAME" --arg DEFINED_TAGS_NAMESPACE "$DEFINED_TAGS_NAMESPACE" '.definedTags[$DEFINED_TAGS_NAMESPACE] += {"Name": $MY_HOSTNAME}' | jq '.definedTags'`
$OCI_BIN compute instance update --instance-id $INSTANCE_ID --defined-tags "$NEW_DEFINED_TAGS" --force

#TODO create a generic bucket with no jvb in the name
BUCKET="jvb-bucket-${ENVIRONMENT}"
$OCI_BIN os object get -bn $BUCKET --name vault-password --file /root/.vault-password
$OCI_BIN os object get -bn $BUCKET --name id_rsa_jitsi_deployment --file /root/.ssh/id_rsa
chmod 400 /root/.ssh/id_rsa

export ENVIRONMENT
export XMPP_DOMAIN
export INSTANCE_ID
export AVAILABILITY_ZONE

#now run ansible
/usr/local/bin/configure-coturn-local-oracle.sh >> /var/log/postinstall-ansible.log 2>&1

