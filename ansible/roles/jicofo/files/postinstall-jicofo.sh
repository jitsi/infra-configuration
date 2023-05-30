#!/usr/bin/env bash

set -e
set -x

#CLEAR AWSMON CACHE
rm -rf /var/tmp/aws-mon/


S3_BUCKET="jitsi-bootstrap-assets"

. /usr/local/bin/aws_cache.sh

EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
EC2_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION


MY_HOSTNAME="${SHARD}-${SHARD_ROLE}.$DOMAIN"

hostname $MY_HOSTNAME

#set AWS Name tag from shard and role
aws ec2 create-tags --resources $EC2_INSTANCE_ID --tags Key=Name,Value="$MY_HOSTNAME"


MY_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

#make sure we have an entry in /etc/hosts for this IP/hostname combination, add it if missing
grep $MY_HOSTNAME /etc/hosts || echo "$MY_IP    $MY_HOSTNAME" >> /etc/hosts

echo "$MY_HOSTNAME" > /etc/hostname

/usr/local/bin/aws s3 cp s3://$S3_BUCKET/vault-password /root/.vault-password
/usr/local/bin/aws s3 cp s3://$S3_BUCKET/id_rsa_jitsi_deployment /root/.ssh/id_rsa
chmod 400 /root/.ssh/id_rsa


export ENVIRONMENT
export SHARD
export CLOUD_NAME
export EC2_INSTANCE_ID
export EC2_AVAIL_ZONE

#now run ansible
/usr/local/bin/configure-jicofo-local.sh >> /var/log/postinstall-ansible.log 2>&1
