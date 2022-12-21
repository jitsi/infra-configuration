#!/bin/bash
set -e

. /usr/local/bin/aws_cache.sh


S3_BUCKET="jitsi-bootstrap-assets"
EC2_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION

MY_IP=`curl -s http://169.254.169.254/latest/meta-data/local-ipv4`
MY_COMPONENT_ID="jibri-$(echo "$MY_IP" | awk -F. '{print $2"-"$3"-"$4}')"

#if there's still no git branch set, assume master
[ -z "$GIT_BRANCH" ] && GIT_BRANCH="master"

#if there's still no git branch set, assume master
[ -z "$JIBRI_GIT_BRANCH" ] && JIBRI_GIT_BRANCH="master"

#set shard to environment if not provided
[ "$SHARD" = "null" ] && SHARD=""
[ -z "$SHARD" ] && SHARD=$ENVIRONMENT

if [ -z "$SHARD" ]; then
    MY_HOSTNAME="${MY_COMPONENT_ID}.jibri.jitsi.net"
else
    if [ -z "$DOMAIN" ]; then
        MY_HOSTNAME="${SHARD}-${MY_COMPONENT_ID}.jibri.jitsi.net"
    else
        MY_HOSTNAME="${SHARD}-${MY_COMPONENT_ID}.$DOMAIN"
    fi
fi
#set our hostname
hostname "$MY_HOSTNAME"
#set AWS Name tag from shard and role
$AWS_BIN ec2 create-tags --resources "$EC2_INSTANCE_ID" --tags Key=Name,Value="$MY_HOSTNAME"

#make sure we have an entry in /etc/hosts for this IP/hostname combination, add it if missing
grep "$MY_HOSTNAME" /etc/hosts || echo "$MY_IP    $MY_HOSTNAME" >> /etc/hosts

mkdir -p /var/run/jibri
chown jibri:jibri /var/run/jibri

/usr/local/bin/aws s3 cp s3://$S3_BUCKET/vault-password /root/.vault-password
/usr/local/bin/aws s3 cp s3://$S3_BUCKET/id_rsa_jitsi_deployment /root/.ssh/id_rsa
chmod 400 /root/.ssh/id_rsa

#now make sure we have the dpkg lock before continuing
echo "Waiting on dpkg lock before continuing"
while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
   echo "Still waiting on dpkg lock"
   sleep 1
done
echo "Dpkg unlocked, running configure-jibri-local.sh"

/usr/local/bin/configure-jibri-local.sh >> /var/log/postinstall-ansible.log 2>&1