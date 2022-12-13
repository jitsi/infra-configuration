#!/usr/bin/env bash

#CLEAR AWSMON CACHE
rm -rf /var/tmp/aws-mon/

XMPP_DOMAIN_TAG="domain"
PUBLIC_DOMAIN_TAG="public_domain"
SHARD_TAG="shard"
SHARD_ROLE_TAG="shard-role"
ENVIRONMENT_TAG="environment"
EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
EC2_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION
EC2_INSTANCE_ID=$(ec2metadata --instance-id)
SHARD=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}" "Name=key,Values=${SHARD_TAG}" | jq .Tags[0].Value -r)

ENVIRONMENT=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}" "Name=key,Values=${ENVIRONMENT_TAG}" | jq .Tags[0].Value -r)

XMPP_DOMAIN=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}" "Name=key,Values=${XMPP_DOMAIN_TAG}" | jq .Tags[0].Value -r)

PUBLIC_DOMAIN=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}" "Name=key,Values=${PUBLIC_DOMAIN_TAG}" | jq .Tags[0].Value -r | grep -v null)

SHARD_ROLE=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}" "Name=key,Values=${SHARD_ROLE_TAG}" | jq .Tags[0].Value -r)

if [ -z "$PUBLIC_DOMAIN" ]; then
	DOMAIN=$XMPP_DOMAIN
else
	DOMAIN=$PUBLIC_DOMAIN
fi

MY_HOSTNAME="${SHARD}-${SHARD_ROLE}.$DOMAIN"

hostname $MY_HOSTNAME

#set AWS Name tag from shard and role
aws ec2 create-tags --resources $EC2_INSTANCE_ID --tags Key=Name,Value="$MY_HOSTNAME"


MY_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

#make sure we have an entry in /etc/hosts for this IP/hostname combination, add it if missing
grep $MY_HOSTNAME /etc/hosts || echo "$MY_IP    $MY_HOSTNAME" >> /etc/hosts

chmod +x /etc/init.d/prosody
/etc/init.d/prosody restart
chmod +x /etc/init.d/nginx
/etc/init.d/nginx restart

chmod +x /etc/init.d/jicofo
/etc/init.d/jicofo restart
