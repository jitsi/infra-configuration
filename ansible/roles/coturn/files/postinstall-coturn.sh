#!/usr/bin/env bash

set -e
set -x

#CLEAR AWSMON CACHE
rm -rf /var/tmp/aws-mon/

S3_BUCKET="jitsi-bootstrap-assets"
XMPP_DOMAIN_TAG="domain"
PUBLIC_DOMAIN_TAG="public_domain"
SHARD_ROLE_TAG="shard-role"
ENVIRONMENT_TAG="environment"
EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
EC2_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION
EC2_INSTANCE_ID=$(ec2metadata --instance-id)

ENVIRONMENT=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}" "Name=key,Values=${ENVIRONMENT_TAG}" | jq .Tags[0].Value -r)

XMPP_DOMAIN=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}" "Name=key,Values=${XMPP_DOMAIN_TAG}" | jq .Tags[0].Value -r)

PUBLIC_DOMAIN=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}" "Name=key,Values=${PUBLIC_DOMAIN_TAG}" | jq .Tags[0].Value -r | grep -v null || echo '')

SHARD_ROLE=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}" "Name=key,Values=${SHARD_ROLE_TAG}" | jq .Tags[0].Value -r)


if [ -z "$PUBLIC_DOMAIN" ]; then
    DOMAIN=$XMPP_DOMAIN
else
    DOMAIN=$PUBLIC_DOMAIN
fi

if [ -z "$DOMAIN" ]; then
    DOMAIN="jitsi.net"
fi

MY_IP=`curl -s http://169.254.169.254/latest/meta-data/local-ipv4`
MY_COMPONENT_ID="coturn-$(echo $MY_IP | awk -F. '{print $4}')"

MY_HOSTNAME="${ENVIRONMENT}-${EC2_REGION}-${MY_COMPONENT_ID}.$DOMAIN"

hostname $MY_HOSTNAME


#set AWS Name tag from environment and role
aws ec2 create-tags --resources $EC2_INSTANCE_ID --tags Key=Name,Value="$MY_HOSTNAME"

#make sure we have an entry in /etc/hosts for this IP/hostname combination, add it if missing
grep $MY_HOSTNAME /etc/hosts || echo "$MY_IP    $MY_HOSTNAME" >> /etc/hosts

echo "$MY_HOSTNAME" > /etc/hostname

/usr/local/bin/aws s3 cp s3://$S3_BUCKET/vault-password /root/.vault-password
/usr/local/bin/aws s3 cp s3://$S3_BUCKET/id_rsa_jitsi_deployment /root/.ssh/id_rsa
chmod 400 /root/.ssh/id_rsa


export ENVIRONMENT
export XMPP_DOMAIN
export EC2_INSTANCE_ID
export EC2_AVAIL_ZONE

#now run ansible
/usr/local/bin/configure-coturn-local.sh >> /var/log/postinstall-ansible.log 2>&1

