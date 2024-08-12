
BSD="/tmp/bootstrap"
LRD="/opt/jitsi/bootstrap"
function check_private_ip() {
  local counter=1
  local ips=1
  while [ $counter -le 2 ]; do
    local pip=$(curl -s curl http://169.254.169.254/opc/v1/vnics/ | jq .[0].privateIp -r)
    if [ -z $pip ] || [ $pip == "null" ]; then
      sleep 30
      ((counter++))
    else
      ips=0
      break
    fi
  done
  if [ $ips -eq 1 ]; then
    echo "Private IP still not available status: $ips" > $tmp_msg_file
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
  DTS="$1"
  CID="$(echo $DTS | jq -r .compartmentId)"
  AD="$(echo $DTS | jq -r .availabilityDomain)"
  REGION="$(echo $DTS | jq -r .regionInfo.regionIdentifier)"
  AVS=$($OCI_BIN bv volume list --compartment-id $CID --lifecycle-state AVAILABLE --region $REGION --availability-domain $AD --auth instance_principal)
  echo $AVS
  if [[ $? -ne 0 ]]; then
    echo "Failed to get list of volumes"
    return 4
  fi
}
function mount_volumes() {
  if [[ "$VOLUMES_ENABLED" == "true" ]]; then
    [ -z "$TAG_NAMESPACE" ] && TAG_NAMESPACE="jitsi"
    IDATA="$(curl -m 10 -s curl http://169.254.169.254/opc/v1/instance/)"
    IID="$(echo $IDATA | jq -r .id)"
    GI="$(echo $IDATA | jq -r '.freeformTags."group-index"')"
    ROLE="$(echo $IDATA | jq -r .definedTags.$TAG_NAMESPACE."role")"
    AVS="$(get_volumes "$IDATA")"
    if [[ $? -eq 0 ]]; then
      RVS="$(echo $AVS | jq ".data | map(select(.\"freeform-tags\".\"volume-role\" == \"$ROLE\"))")"
      GVS="$(echo $RVS | jq "map(select(.\"freeform-tags\".\"volume-index\" == \"$GI\"))")"
      GVC="$(echo $GVS | jq length)"
      if [[ "$GVC" -gt 0 ]]; then
        for i in `seq 0 $((GVC-1))`; do
          VD="$(echo $GVS | jq -r ".[$i]")"
          VT="$(echo $VD | jq -r .\"freeform-tags\".\"volume-type\")"
          VL="$VT-$GROUP_INDEX"
          mount_volume "$VD" $VL $IID
        done
      else
        echo "No volumes found matching role $ROLE and group index $GI"
      fi
      NGVS="$(echo $RVS | jq "map(select(.\"freeform-tags\".\"volume-index\" == null))")"
      NGVSC="$(echo $NGVS | jq length)"
      if [[ "$NGVSC" -gt 0 ]]; then
        for i in `seq 0 $((NGVSC-1))`; do
          VD="$(echo $NGVS | jq -r ".[$i]")"
          VT="$(echo $VD | jq -r .\"freeform-tags\".\"volume-type\")"
          VL="$VOLUME_TYPE"
          mount_volume "$VD" $VL $IID
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
    mcn="$(echo $MY_IP | awk -F. '{print $2"-"$3"-"$4}')"
    MY_HOSTNAME="$CLOUD_NAME-$TYPE-$mcn.$DOMAIN"
  fi
  hostname $MY_HOSTNAME
  grep $MY_HOSTNAME /etc/hosts || echo "$MY_IP    $MY_HOSTNAME" >> /etc/hosts
  echo "$MY_HOSTNAME" > /etc/hostname
}
function checkout_repos() {
  [ -d $BSD/infra-configuration ] && rm -rf $BSD/infra-configuration
  [ -d $BSD/infra-customizations ] && rm -rf $BSD/infra-customizations
  if [ ! -n "$(grep "^github.com " ~/.ssh/known_hosts)" ]; then ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null; fi
  mkdir -p "$BSD"
  if [ -d "$LRD" ]; then
    echo "Found local repo copies in $LRD, using instead of clone"
    cp -a $LRD/infra-configuration $BSD
    cp -a $LRD/infra-customizations $BSD
    cd $BSD/infra-configuration
    git pull
    cd -
    cd $BSD/infra-customizations
    git pull
    cd -
  else
    echo "No local repos found, cloning directly from github"
    git clone $INFRA_CONFIGURATION_REPO $BSD/infra-configuration
    git clone $INFRA_CUSTOMIZATIONS_REPO $BSD/infra-customizations
  fi
  cd $BSD/infra-configuration
  git checkout $GIT_BRANCH
  git submodule update --init --recursive
  git show-ref heads/$GIT_BRANCH || git show-ref tags/$GIT_BRANCH
  cd -
  cd $BSD/infra-customizations
  git checkout $GIT_BRANCH
  git submodule update --init --recursive
  git show-ref heads/$GIT_BRANCH || git show-ref tags/$GIT_BRANCH
  cp -a $BSD/infra-customizations/* $BSD/infra-configuration
  cd -
}
function run_ansible_playbook() {
    cd $BSD/infra-configuration
    PLAYBOOK=$1
    VARS=$2
    DEPLOY_TAGS=${ANSIBLE_TAGS-"all"}
    sc=0
    ansible-playbook -v \
        -i "127.0.0.1," \
        -c local \
        --tags "$DEPLOY_TAGS" \
        --extra-vars "$VARS" \
        --vault-password-file=/root/.vault-password \
        ansible/$PLAYBOOK || sc=1
    if [ $sc -eq 1 ]; then
        echo 'Provisioning stage failed' > $tmp_msg_file;
    fi
    cd -
    return $sc
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
  local sc=0
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
  run_ansible_playbook "$ANSIBLE_PLAYBOOK"  "$ANSIBLE_VARS" || sc=1
  return $sc;
}
function default_terminate() {
  echo "Terminating"
  INSTANCE_ID=`curl --connect-timeout 10 -s curl http://169.254.169.254/opc/v1/instance/ | jq -r .id`
  sudo /usr/local/bin/oci compute instance terminate --debug --instance-id "$INSTANCE_ID" --preserve-boot-volume false --auth instance_principal --force
  RET=$?
  # infinite loop on failure
  if [ $RET -gt 0 ]; then
    echo "Failed to terminate, exit code: $RET, sleep 10 retry"
    sleep 10
    default_terminate
  fi
}
# end of postinstall-lib, next line blank



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
