
BOOTSTRAP_DIRECTORY="/tmp/bootstrap"
LOCAL_REPO_DIRECTORY="/opt/jitsi/bootstrap"
function check_private_ip() {
  local counter=1
  local ip_status=1
  while [ $counter -le 2 ]; do
    local my_private_ip=$(curl -s curl http://169.254.169.254/opc/v1/vnics/ | jq .[0].privateIp -r)
    if [ -z $my_private_ip ] || [ $my_private_ip == "null" ]; then
      sleep 30
      ((counter++))
    else
      ip_status=0
      break
    fi
  done
  if [ $ip_status -eq 1 ]; then
    echo "Private IP still not available status: $ip_status" > $tmp_msg_file
    return 1
  else
    return 0
  fi
}
function retry() {
  local n=0
  RETRIES=$2
  [ -z "$RETRIES" ] && RETRIES=10
  until [ $n -ge $RETRIES ]
  do
    # call the function given as parameter
    $1
    # check the result of the function
    if [ $? -eq 0 ]; then
      # success
      > $tmp_msg_file
      break
    else
      # failure, therefore retry
      n=$[$n+1]
      # only sleep if we're not going to be done with the loop
      if [ $n -lt $RETRIES ]; then
        sleep 10
      fi
    fi
  done
  if [ $n -eq $RETRIES ]; then
    return $n
  else
    return 0;
  fi
}
function add_ip_tags() {
    . /usr/local/bin/oracle_cache.sh
    vnic_id=$(curl -s curl http://169.254.169.254/opc/v1/vnics/ | jq .[0].vnicId -r)
    vnic_details_result=$(oci network vnic get --vnic-id "$vnic_id" --auth instance_principal)
    if [ $? -eq 0 ]; then
        PUBLIC_IP=$(echo "$vnic_details_result" | jq -r '.data["public-ip"]')
        PRIVATE_IP=$(echo "$vnic_details_result" | jq -r '.data["private-ip"]')
        IMAGE=$(curl -s curl http://169.254.169.254/opc/v1/instance/ | jq -r '.image')
        [ "$IMAGE" == "null" ] && IMAGE=""
        [ ! -z "$IMAGE" ] && IMAGE_ITEM=", \"image\": \"$IMAGE\""
        [ "$PUBLIC_IP" == "null" ] && PUBLIC_IP=""
        [ ! -z "$PUBLIC_IP" ] && PUBLIC_IP_ITEM=", \"public_ip\": \"$PUBLIC_IP\""
        ITEM="{\"private_ip\": \"$PRIVATE_IP\"${PUBLIC_IP_ITEM}${IMAGE_ITEM}}"
        INSTANCE_METADATA=`$OCI_BIN compute instance get --instance-id $INSTANCE_ID | jq .`
        INSTANCE_ETAG=$(echo $INSTANCE_METADATA | jq -r '.etag')
        NEW_FREEFORM_TAGS=$(echo $INSTANCE_METADATA | jq --argjson ITEM "$ITEM" '.data["freeform-tags"] += $ITEM' | jq '.data["freeform-tags"]')
        $OCI_BIN compute instance update --instance-id $INSTANCE_ID --freeform-tags "$NEW_FREEFORM_TAGS" --if-match "$INSTANCE_ETAG" --force
        rm /tmp/oracle_cache-ocid* || echo "No cache to delete"
    else
      return 2
    fi
}

function next_device() { 
  DEVICE_PREFIX="/dev/oracleoci/oraclevd"
  ALPHA=( {a..z} ) 
  for i in {0..25}; do 
    DEVICE="${DEVICE_PREFIX}${ALPHA[$i]}"
    if [ ! -e $DEVICE ]; then 
      echo $DEVICE
      return 0
    fi
  done
}

function init_volume() {
  DEVICE=$1
  LABEL=$2
  VOLUME=$3
  TAGS="$4"
  mkfs -t ext4 $DEVICE
  if [[ $? -eq 0 ]]; then
    e2label $DEVICE $LABEL
    NEW_TAGS="$(echo $TAGS '{"volume-format":"ext4"}' | jq -s '.|add')"
    echo "Applying new tags $NEW_TAGS to volume $VOLUME"
    $OCI_BIN bv volume update --volume-id $VOLUME --freeform-tags "$NEW_TAGS" --force --auth instance_principal
  else
    echo "Error initializing volume $VOLUME"
    return 3
  fi
}
mount_volume() {
  VOLUME_DETAIL="$1"
  VOLUME_LABEL="$2"
  INSTANCE="$3"
  mount | grep -q $VOLUME_LABEL
  if [[ $? -eq 0 ]]; then
    echo "Volume $VOLUME_LABEL already mounted"
    return 0
  fi
  volume="$(echo $VOLUME_DETAIL | jq -r .id)"
  VOLUME_FORMAT="$(echo $VOLUME_DETAIL | jq -r .\"freeform-tags\".\"volume-format\")"
  VOLUME_TAGS="$(echo $VOLUME_DETAIL | jq  .\"freeform-tags\")"
  VOLUME_PATH="/mnt/bv/$VOLUME_LABEL"
  NEXT_DEVICE="$(next_device)"
  $OCI_BIN compute volume-attachment attach --instance-id $INSTANCE --volume-id $volume --type paravirtualized --device $NEXT_DEVICE --auth instance_principal --wait-for-state ATTACHED
  if [[ $? -eq 0 ]]; then
    echo "Volume $volume $VOLUME_PATH attached successfully"
    if [[ "$VOLUME_FORMAT" == "null" ]]; then
      echo "Initializing volume $volume"
      init_volume $NEXT_DEVICE $VOLUME_LABEL $volume "$VOLUME_TAGS"
    else
      echo "Volume $volume $VOLUME_PATH already initialized"
    fi
    echo "Adding volume to fstab"
    grep -q "$VOLUME_PATH" /etc/fstab || echo 'LABEL="'$VOLUME_LABEL'" '$VOLUME_PATH' ext4 defaults,nofail 0 2' >> /etc/fstab
    [ -d "$VOLUME_PATH" ] || mkdir -p $VOLUME_PATH
    echo "Mounting volume $volume $VOLUME_PATH"
    mount $VOLUME_PATH
    if [[ $? -eq 0 ]]; then
      echo "Volume $volume $VOLUME_PATH mounted successfully"
      return 0
    else
      echo "Failed to mount volume $volume $VOLUME_PATH"
      return 5
    fi
  else
    echo "Failed to attach volume $volume"
    return 6
  fi
}
function get_volumes() {
  DETAILS="$1"
  COMPARTMENT_ID="$(echo $DETAILS | jq -r .compartmentId)"
  AD="$(echo $DETAILS | jq -r .availabilityDomain)"
  REGION="$(echo $DETAILS | jq -r .regionInfo.regionIdentifier)"
  ALL_VOLUMES=$($OCI_BIN bv volume list --compartment-id $COMPARTMENT_ID --lifecycle-state AVAILABLE --region $REGION --availability-domain $AD --auth instance_principal)
  echo $ALL_VOLUMES
  if [[ $? -ne 0 ]]; then
    echo "Failed to get list of volumes"
    return 4
  fi
}
function mount_volumes() {
  if [[ "$VOLUMES_ENABLED" == "true" ]]; then
    [ -z "$TAG_NAMESPACE" ] && TAG_NAMESPACE="jitsi"
    INSTANCE_DATA="$(curl --connect-timeout 10 -s curl http://169.254.169.254/opc/v1/instance/)"
    INSTANCE_ID="$(echo $INSTANCE_DATA | jq -r .id)"
    GROUP_INDEX="$(echo $INSTANCE_DATA | jq -r '.freeformTags."group-index"')"
    ROLE="$(echo $INSTANCE_DATA | jq -r .definedTags.$TAG_NAMESPACE."role")"
    ALL_VOLUMES="$(get_volumes "$INSTANCE_DATA")"
    if [[ $? -eq 0 ]]; then
      ROLE_VOLUMES="$(echo $ALL_VOLUMES | jq ".data | map(select(.\"freeform-tags\".\"volume-role\" == \"$ROLE\"))")"
      GROUP_VOLUMES="$(echo $ROLE_VOLUMES | jq "map(select(.\"freeform-tags\".\"volume-index\" == \"$GROUP_INDEX\"))")"
      GROUP_VOLUMES_COUNT="$(echo $GROUP_VOLUMES | jq length)"
      if [[ "$GROUP_VOLUMES_COUNT" -gt 0 ]]; then
        for i in `seq 0 $((GROUP_VOLUMES_COUNT-1))`; do
          VOLUME_DETAIL="$(echo $GROUP_VOLUMES | jq -r ".[$i]")"
          VOLUME_TYPE="$(echo $VOLUME_DETAIL | jq -r .\"freeform-tags\".\"volume-type\")"
          VOLUME_LABEL="$VOLUME_TYPE-$GROUP_INDEX"
          mount_volume "$VOLUME_DETAIL" $VOLUME_LABEL $INSTANCE_ID
        done
      else
        echo "No volumes found matching role $ROLE and group index $GROUP_INDEX"
      fi
      NON_GROUP_VOLUMES="$(echo $ROLE_VOLUMES | jq "map(select(.\"freeform-tags\".\"volume-index\" == null))")"
      NON_GROUP_VOLUMES_COUNT="$(echo $NON_GROUP_VOLUMES | jq length)"
      if [[ "$NON_GROUP_VOLUMES_COUNT" -gt 0 ]]; then
        for i in `seq 0 $((NON_GROUP_VOLUMES_COUNT-1))`; do
          VOLUME_DETAIL="$(echo $NON_GROUP_VOLUMES | jq -r ".[$i]")"
          VOLUME_TYPE="$(echo $VOLUME_DETAIL | jq -r .\"freeform-tags\".\"volume-type\")"
          VOLUME_LABEL="$VOLUME_TYPE"
          mount_volume "$VOLUME_DETAIL" $VOLUME_LABEL $INSTANCE_ID || echo "Failed to mount non-group volume $VOLUME_LABEL, may be mounted elsewhere"
        done
      else
        echo "No volumes found matching role $ROLE with no group index"
      fi
    fi
  fi
}
function fetch_credentials() {
  ENVIRONMENT=$1
  BUCKET="jvb-bucket-${ENVIRONMENT}"
  $OCI_BIN os object get -bn $BUCKET --name vault-password --file /root/.vault-password
  $OCI_BIN os object get -bn $BUCKET --name id_rsa_jitsi_deployment --file /root/.ssh/id_rsa
  chmod 400 /root/.ssh/id_rsa
}
function clean_credentials() {
  rm /root/.vault-password /root/.ssh/id_rsa
}
function set_hostname() {
  TYPE=$1
  MY_HOSTNAME=$2
  MY_IP=`curl -s curl http://169.254.169.254/opc/v1/vnics/ | jq .[0].privateIp -r`
  if [ -z "$MY_HOSTNAME" ]; then
    #clear domain if null
    [ "$DOMAIN" == "null" ] && DOMAIN=
    [ -z "$DOMAIN" ] && DOMAIN="oracle.jitsi.net"
    MY_COMPONENT_NUMBER="$(echo $MY_IP | awk -F. '{print $2"-"$3"-"$4}')"
    MY_HOSTNAME="$CLOUD_NAME-$TYPE-$MY_COMPONENT_NUMBER.$DOMAIN"
  fi
  hostname $MY_HOSTNAME
  grep $MY_HOSTNAME /etc/hosts || echo "$MY_IP    $MY_HOSTNAME" >> /etc/hosts
  echo "$MY_HOSTNAME" > /etc/hostname
}
function checkout_repos() {
  [ -d $BOOTSTRAP_DIRECTORY/infra-configuration ] && rm -rf $BOOTSTRAP_DIRECTORY/infra-configuration
  [ -d $BOOTSTRAP_DIRECTORY/infra-customizations ] && rm -rf $BOOTSTRAP_DIRECTORY/infra-customizations
  if [ ! -n "$(grep "^github.com " ~/.ssh/known_hosts)" ]; then ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null; fi
  mkdir -p "$BOOTSTRAP_DIRECTORY"
  if [ -d "$LOCAL_REPO_DIRECTORY" ]; then
    echo "Found local repo copies in $LOCAL_REPO_DIRECTORY, setting GIT_ALTERNATE_OBJECT_DIRECTORIES"
    export GIT_ALTERNATE_OBJECT_DIRECTORIES="$LOCAL_REPO_DIRECTORY/infra-configuration/.git/objects:$LOCAL_REPO_DIRECTORY/infra-customizations/.git/objects"
  fi
  echo "Now cloning directly from github"
  git clone $INFRA_CONFIGURATION_REPO $BOOTSTRAP_DIRECTORY/infra-configuration
  git clone $INFRA_CUSTOMIZATIONS_REPO $BOOTSTRAP_DIRECTORY/infra-customizations
  cd $BOOTSTRAP_DIRECTORY/infra-configuration
  git checkout $GIT_BRANCH
  git show-ref heads/$GIT_BRANCH || git show-ref tags/$GIT_BRANCH
  cd /root
  cd $BOOTSTRAP_DIRECTORY/infra-customizations
  git checkout $GIT_BRANCH
  git show-ref heads/$GIT_BRANCH || git show-ref tags/$GIT_BRANCH
  cp -a $BOOTSTRAP_DIRECTORY/infra-customizations/* $BOOTSTRAP_DIRECTORY/infra-configuration
  cd /root
}
function run_ansible_playbook() {
    cd $BOOTSTRAP_DIRECTORY/infra-configuration
    PLAYBOOK=$1
    VARS=$2
    DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}
    ansible-playbook -v \
        -i "127.0.0.1," \
        -c local \
        --tags "$DEPLOY_TAGS" \
        --extra-vars "$VARS" \
        --vault-password-file=/root/.vault-password \
        ansible/$PLAYBOOK || status_code=1
    if [ $status_code -eq 1 ]; then
        echo 'Provisioning stage failed' > $tmp_msg_file;
    fi
    cd /root
    return $status_code
}
function default_dump() {
  sudo /usr/local/bin/dump-boot.sh
}
function default_main() {
  [ -z "$PROVISION_COMMAND" ] && PROVISION_COMMAND="default_provision"
  [ -z "$CLEAN_CREDENTIALS" ] && CLEAN_CREDENTIALS="true"
  EXIT_CODE=0
  ( retry check_private_ip && retry add_ip_tags && retry mount_volumes && retry $PROVISION_COMMAND ) ||  EXIT_CODE=1
  if [ "$CLEAN_CREDENTIALS" == "true" ]; then
    clean_credentials
  fi
  return $EXIT_CODE
}
function default_provision() {
  local status_code=0
  . /usr/local/bin/oracle_cache.sh
  fetch_credentials $ENVIRONMENT
  [ -z "$HOST_ROLE" ] && HOST_ROLE="$SHARD_ROLE"
  if [ -z "$HOST_ROLE" ]; then
    echo "No HOST_ROLE role set"
    return 1
  fi
  if [ -z "$ANSIBLE_PLAYBOOK" ]; then
    echo "No ANSIBLE_PLAYBOOK set"
    return 2
  fi
  if [ -z "$ANSIBLE_VARS" ]; then
    echo "No ANSIBLE_VARS set"
    return 3
  fi
  set_hostname "$HOST_ROLE" "$MY_HOSTNAME"
  if [ -z "$INFRA_CONFIGURATION_REPO" ]; then
    export INFRA_CONFIGURATION_REPO="https://github.com/jitsi/infra-configuration.git"
  fi
  checkout_repos
  run_ansible_playbook "$ANSIBLE_PLAYBOOK"  "$ANSIBLE_VARS" || status_code=1
  return $status_code;
}
function default_terminate() {
  echo "Terminating the instance; we enable debug to have more details in case of oci cli failures"
  INSTANCE_ID=`curl --connect-timeout 10 -s curl http://169.254.169.254/opc/v1/instance/ | jq -r .id`
  sudo /usr/local/bin/oci compute instance terminate --debug --instance-id "$INSTANCE_ID" --preserve-boot-volume false --auth instance_principal --force
  RET=$?
  # infinite loop on failure
  if [ $RET -gt 0 ]; then
    echo "Failed to terminate instance, exit code: $RET, sleeping 10 then retrying"
    sleep 10
    default_terminate
  fi
}
# end of postinstall-lib, this space intentionally left blank



function should_assign_eip() {
  use_eip=$(curl -s curl http://169.254.169.254/opc/v1/instance/ | jq '."definedTags" | to_entries[] | select((.key | startswith("eghtjitsi")) or (.key == "jitsi")) |.value."use_eip"' -r)

  if [ ! -z "$use_eip" ] && [ "$use_eip" == 'true' ]; then
    echo "Will assign a reserved public ip to the instance"
    return 0
  else
    echo "The instance has an ephemeral public ip assigned"
    return 1
  fi
}

function switch_to_secondary_vnic() {
  status_code=0
  echo "Configure secondary NIC with routing"
  sudo /usr/local/bin/secondary_vnic_all_configure_oracle.sh -c || status_code=1

  if [ $status_code -gt 0 ]; then
    return $status_code
  fi

  echo "Detect secondary NIC"
  SECONDARY_VNIC_DEVICE="$(ip addr | egrep '^[0-9]' | egrep -v 'lo|docker' | tail -1 | awk '{print $2}')"
  SECONDARY_VNIC_DEVICE="${SECONDARY_VNIC_DEVICE::-1}"
  SECONDARY_VNIC_DEVICE="$(echo $SECONDARY_VNIC_DEVICE | cut -d'@' -f1)"

  echo "Switch default routes to NIC2"
  export NIC1_ROUTE_1=$(ip route show | grep default -m 1)
  sudo ip route delete $NIC1_ROUTE_1 || status_code=1

  if [ $status_code -gt 0 ]; then
    return $status_code
  fi

  # 
  export NIC1_ROUTE_2=$(ip route show | grep default -m 1)
  if [ ! -z "$NIC1_ROUTE_2" ]; then
    sudo ip route delete $NIC1_ROUTE_2 || status_code=1
  fi

  if [ $status_code -gt 0 ]; then
    return $status_code
  fi

  export NIC2_ROUTE="default via "$(ip route show | grep $SECONDARY_VNIC_DEVICE | awk '{ print substr($1,1,index($1,"/")-2)1 " " $2 " " $3}')
  sudo ip route add $NIC2_ROUTE || status_code=1
  return $status_code
}

function switch_to_primary_vnic() {
  status_code=0
  echo "Switch default route back to NIC1"

  sudo ip route delete $NIC2_ROUTE || status_code=1

  if [ $status_code -gt 0 ]; then
    return $status_code
  fi

  sudo ip route add $NIC1_ROUTE_1 || status_code=1

  if [ $status_code -gt 0 ]; then
    return $status_code
  fi

  if [ ! -z "$NIC1_ROUTE_2" ]; then
    sudo ip route add $NIC1_ROUTE_2 || status_code=1

    if [ $status_code -gt 0 ]; then
      return $status_code
    fi
  fi
  echo "Delete secondary NIC routing to avoid routing issues in the future"
  sudo /usr/local/bin/secondary_vnic_all_configure_oracle.sh -d || status_code=1
  return $status_code
}

function assign_reserved_public_ip() {
  [ -z "$PUBLIC_IP_ROLE" ] && PUBLIC_IP_ROLE="JVB"

  vnic_id=$(curl -s curl http://169.254.169.254/opc/v1/vnics/ | jq .[0].vnicId -r)
  vnic_details_result=$(oci network vnic get --vnic-id "$vnic_id" --auth instance_principal)
  if [ $? -eq 0 ]; then
    public_ip=$(echo "$vnic_details_result" | jq -r '.data["public-ip"]')

    private_ip=$(echo "$vnic_details_result" | jq -r '.data["private-ip"]')
    subnet_id=$(echo "$vnic_details_result" | jq -r '.data["subnet-id"]')
    private_ip_details=$(oci network private-ip list --subnet-id "$subnet_id" --ip-address "$private_ip" --auth instance_principal)
    private_ip_ocid=$(echo "$private_ip_details" | jq -r '.data[0] | .id')

    echo "Public ip is: $public_ip"

    if [ -z "$public_ip" ] || [ "$public_ip" == "null" ]; then
      echo "Search for a reserved public ip"
      compartment_id=$(echo "$vnic_details_result" | jq -r '.data["compartment-id"]')
      tag_namespace="jitsi"
      reserved_ips=$(oci network public-ip list --compartment-id "$compartment_id" --scope REGION --lifetime RESERVED --all --query 'data[?"defined-tags".'\"$tag_namespace\"'."shard-role" == `'$PUBLIC_IP_ROLE'`]' --auth instance_principal)

      reserved_unasigned_ips_count=$(echo "$reserved_ips" | jq '[.[] | select(."lifecycle-state" == "AVAILABLE")] | length' -r)
      if [ "$reserved_unasigned_ips_count" == 0 ]; then
        echo "No AVAILABLE and UNASIGNED reserved IPs. Exiting.."
        return 1
      fi
      random_ip_index=$(((RANDOM % reserved_unasigned_ips_count)))
      reserved_public_ip=$(echo "$reserved_ips" | jq --arg index "$random_ip_index" '[.[] | select(."lifecycle-state" == "AVAILABLE")][$index|tonumber] | ."ip-address"' -r)
      reserved_public_ip_ocid=$(echo "$reserved_ips" | jq --arg index "$random_ip_index" '[.[] | select(."lifecycle-state" == "AVAILABLE")][$index|tonumber] | ."id"' -r)

      reserved_public_ip_details=$(oci network public-ip get --public-ip-address "$reserved_public_ip" --auth instance_principal)
      reserved_public_ip_state=$(echo "$reserved_public_ip_details" | jq -r '.data["lifecycle-state"]')
      if [ "$reserved_public_ip_state" == "ASSIGNED" ]; then
        echo "Public ip $reserved_public_ip was assigned in the meantime to another instance"
        return 1
      fi

      etag_reserved_public_ip=$(echo "$reserved_public_ip_details" | jq -r '.etag')

      echo "Found unasigned public ip: $reserved_public_ip"

      echo "Assign public ip $reserved_public_ip to private ip: $private_ip"
      oci network public-ip update --public-ip-id "$reserved_public_ip_ocid" --private-ip-id "$private_ip_ocid" --wait-for-state ASSIGNED --if-match "$etag_reserved_public_ip" --max-wait-seconds 180 --auth instance_principal
      if [ "$?" -gt 0 ]; then
        echo "Failed assigning public ip to private ip"
        return 1
      else
        echo "Successfully assigned public ip: $reserved_public_ip to private ip $private_ip"
        return 0
      fi
    else
      echo "Public ip $public_ip already assigned"
      return 0
    fi
  else
    echo "Failed to determine IP status, waiting before retry"
    sleep 1
    return 1
  fi
}

function assign_ephemeral_public_ip() {
  vnic_id=$(curl -s curl http://169.254.169.254/opc/v1/vnics/ | jq .[0].vnicId -r)
  vnic_details_result=$(oci network vnic get --vnic-id "$vnic_id" --auth instance_principal)
  compartment_id=$(echo "$vnic_details_result" | jq -r '.data["compartment-id"]')
  public_ip=$(echo "$vnic_details_result" | jq -r '.data["public-ip"]')

  private_ip=$(echo "$vnic_details_result" | jq -r '.data["private-ip"]')
  subnet_id=$(echo "$vnic_details_result" | jq -r '.data["subnet-id"]')
  private_ip_details=$(oci network private-ip list --subnet-id "$subnet_id" --ip-address "$private_ip" --auth instance_principal)
  private_ip_ocid=$(echo "$private_ip_details" | jq -r '.data[0] | .id')

  echo "Public ip is: $public_ip"

  if [ -z "$public_ip" ] || [ "$public_ip" == "null" ]; then
    echo "Create and assign ephemeral public ip"
    oci network public-ip create --compartment-id "$compartment_id" --lifetime EPHEMERAL --private-ip-id "$private_ip_ocid" --wait-for-state ASSIGNED --auth instance_principal
    if [ "$?" -gt 0 ]; then
      echo "Failed assigning ephemeral public ip to private ip"
      return 1
    else
      echo "Successfully assigned ephemeral public ip to private ip $private_ip"
      return 0
    fi
  else
    echo "Public ip $public_ip already assigned"
    return 0
  fi
}

function check_secondary_ip() {
  local counter=1
  local ip_status=1

  while [ $counter -le 2 ]; do
    local my_private_ip=$(curl -s curl http://169.254.169.254/opc/v1/vnics/ | jq .[1].privateIp -r)

    if [ -z "$my_private_ip" ] || [ "$my_private_ip" == "null" ]; then
      sleep 30
      ((counter++))
    else
      ip_status=0
      break
    fi
  done

  if [ $ip_status -eq 1 ]; then
    echo "Secondary private IP still not available status: $ip_status" >$tmp_msg_file
    return 1
  else
    return 0
  fi
}

eip_assign() {
  [ -z "$PROVISION_COMMAND" ] && PROVISION_COMMAND="default_provision"

  EIP_EXIT_CODE=0
  (retry check_secondary_ip) || EIP_EXIT_CODE=1

  if [ $EIP_EXIT_CODE -eq 0 ]; then
      switch_to_secondary_vnic || EIP_EXIT_CODE=1
  fi

  if [ $EIP_EXIT_CODE -eq 0 ]; then
      (retry assign_reserved_public_ip 15 || retry assign_ephemeral_public_ip) || EIP_EXIT_CODE=1
      switch_to_primary_vnic || EIP_EXIT_CODE=1
  else
      switch_to_primary_vnic || EIP_EXIT_CODE=1
  fi

  if [ $EIP_EXIT_CODE -eq 0 ]; then
      (retry add_ip_tags && retry $PROVISION_COMMAND) || EIP_EXIT_CODE=1
  fi
  return $EIP_EXIT_CODE
}

function eip_main() {
  EXIT_CODE=0

  [ -z "$PROVISION_COMMAND" ] && PROVISION_COMMAND="default_provision"
  [ -z "$CLEAN_CREDENTIALS" ] && CLEAN_CREDENTIALS="true"

  if [ $EXIT_CODE -eq 0 ]; then
    if should_assign_eip; then
      eip_assign || EXIT_CODE=1
    else
        # we should not assign eip, therefore we assume we already have a public ip
        (retry check_private_ip && retry add_ip_tags && retry $PROVISION_COMMAND) || EXIT_CODE=1
    fi
  else
    echo "Failed to get private IP, no further provisioning possible.  This instance requires manual intervention"
  fi

  return $EXIT_CODE
}
# end of postinstall-eip-lib, this space intentionally left blank
