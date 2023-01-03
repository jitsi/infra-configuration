#!/bin/bash

#!/bin/bash
set -e

. /usr/local/bin/aws_cache.sh

set -x

GRID_TAG="grid"
GRID_ROLE_TAG="grid-role"
CACHE_PATH="/tmp/aws_cache-${EC2_INSTANCE_ID}"

GRID_ROLE=$(jq -r ".Tags[] | select(.Key == \"$GRID_ROLE_TAG\") | .Value" < "$CACHE_PATH")
GRID=$(jq -r ".Tags[] | select(.Key == \"$GRID_TAG\") | .Value" < "$CACHE_PATH")

S3_BUCKET="jitsi-bootstrap-assets"
EC2_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)
export AWS_DEFAULT_REGION=$EC2_REGION

MY_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
MY_COMPONENT_ID="selenium-${GRID_ROLE}-$(echo "$MY_IP" | awk -F. '{print $3$4}')"
GIT_BRANCH_TAG="git_branch"

#search for the git branch attached to this instance
[ -z "$GIT_BRANCH" ] && GIT_BRANCH=$($AWS_BIN ec2 describe-tags --filters "Name=resource-id,Values=${EC2_INSTANCE_ID}" "Name=key,Values=${GIT_BRANCH_TAG}" | jq .Tags[0].Value -r)

#if we get "null" back from the tags, then assume master
[ "$GIT_BRANCH" == "null" ] && GIT_BRANCH="master"

#if there's still no git branch set, assume master
[ -z "$GIT_BRANCH" ] && GIT_BRANCH="master"

MY_HOSTNAME="${MY_COMPONENT_ID}.${GRID}.jitsi.net"

#set our hostname
hostname "$MY_HOSTNAME"
#set AWS Name tag from shard and role
$AWS_BIN ec2 create-tags --resources "$EC2_INSTANCE_ID" --tags Key=Name,Value="$MY_HOSTNAME"

#make sure we have an entry in /etc/hosts for this IP/hostname combination, add it if missing
grep "$MY_HOSTNAME" /etc/hosts || echo "$MY_IP    $MY_HOSTNAME" >> /etc/hosts

/usr/local/bin/aws s3 cp s3://$S3_BUCKET/vault-password /root/.vault-password
/usr/local/bin/aws s3 cp s3://$S3_BUCKET/id_rsa_jitsi_deployment /root/.ssh/id_rsa
chmod 400 /root/.ssh/id_rsa

#now make sure we have the dpkg lock before continuing
echo "Waiting on dpkg lock before continuing"
while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
   echo "Still waiting on dpkg lock"
   sleep 1
done
echo "Dpkg unlocked, running ansible-pull"

DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}

ansible-pull -v -U git@github.com:8x8Cloud/jitsi-video-infrastructure.git \
-d /tmp/bootstrap --purge \
-i \"127.0.0.1,\" \
--vault-password-file=/root/.vault-password \
--accept-host-key \
-C "$GIT_BRANCH" \
--tags "$DEPLOY_TAGS" \
--extra-vars "selenium_grid_role=$GRID_ROLE selenium_grid_name=$GRID" \
ansible/configure-selenium-grid-local.yml
