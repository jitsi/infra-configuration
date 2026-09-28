#!/bin/bash
set -e
set -x

. /usr/local/bin/oracle_cache.sh

# The current defined tags come from the instance metadata service rather than an
# oci compute instance get: every oci call pays a python start-up of several
# seconds at boot. Metadata carries no etag, so the update is unconditional;
# nothing else writes defined tags this early (add_ip_tags only writes freeform).
function add_name_tag() {
  INSTANCE_ID=$1
  MY_HOSTNAME=$2

  INSTANCE_METADATA=$(curl -s http://169.254.169.254/opc/v1/instance/)
  DEFINED_TAGS_NAMESPACE="jitsi"
  # refuse rather than write back a tag set that lost the namespace
  NEW_DEFINED_TAGS=$(echo "$INSTANCE_METADATA" | jq -e --arg MY_HOSTNAME "$MY_HOSTNAME" --arg DEFINED_TAGS_NAMESPACE "$DEFINED_TAGS_NAMESPACE" 'select(.definedTags[$DEFINED_TAGS_NAMESPACE] != null) | .definedTags[$DEFINED_TAGS_NAMESPACE] += {"Name": $MY_HOSTNAME} | .definedTags') || return 1
  [ -n "$NEW_DEFINED_TAGS" ] || return 1
  $OCI_BIN compute instance update --instance-id $INSTANCE_ID --defined-tags "$NEW_DEFINED_TAGS" --force
}

MY_IP=$(curl -s curl http://169.254.169.254/opc/v1/vnics/ | jq .[0].privateIp -r)
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

#make sure we have an entry in /etc/hosts for this IP/hostname combination, add it if missing
grep "$MY_HOSTNAME" /etc/hosts || echo "$MY_IP    $MY_HOSTNAME" >>/etc/hosts

#set Name tag by getting current freeform-tags/defined-tags and appending the name tag
#do not fail immediately for this part, as we want to do one retry for tags update
set +e
add_name_tag "$INSTANCE_ID" "$MY_HOSTNAME"

if [ $? -gt 0 ]; then
  echo "Failed to update the tags, doing another retry in 5 seconds"
  sleep 5
  add_name_tag "$INSTANCE_ID" "$MY_HOSTNAME"

  if [ $? -gt 0 ]; then
    echo "Error while updating the Name tag on the instance. Exiting..."
    exit 1
  fi
fi
set -e

mkdir -p /var/run/jibri
chown jibri:jibri /var/run/jibri

#TODO create a generic bucket with no jvb in the name
BUCKET="jvb-bucket-${ENVIRONMENT}"
# independent downloads, so pay the oci start-up for both at once; set -e still
# stops the script if either fails
$OCI_BIN os object get -bn "$BUCKET" --name vault-password --file /root/.vault-password &
VAULT_PASSWORD_PID=$!
$OCI_BIN os object get -bn "$BUCKET" --name id_rsa_jitsi_deployment --file /root/.ssh/id_rsa &
DEPLOY_KEY_PID=$!
wait $VAULT_PASSWORD_PID
wait $DEPLOY_KEY_PID
chmod 400 /root/.ssh/id_rsa

#now make sure we have the dpkg lock before continuing
echo "Waiting on dpkg lock before continuing"
while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
  echo "Still waiting on dpkg lock"
  sleep 1
done
echo "Dpkg unlocked, running configure-jibri-local.sh"

/usr/local/bin/configure-jibri-local.sh >>/var/log/postinstall-ansible.log 2>&1
