#!/bin/bash

export OCI_BIN="/usr/local/bin/oci"
export CURL_BIN="/usr/bin/curl"
export JQ_BIN="/usr/bin/jq"

# notify the sidecar of imminent shutdown
$CURL_BIN -d '{}' -v localhost:6000/hook/v1/shutdown
sleep 10

if [ -z "$INSTANCE_ID" ]; then
    INSTANCE_ID=$($CURL_BIN -s http://169.254.169.254/opc/v1/instance/ | $JQ_BIN .id -r)
fi

function oci_api_reachable() {
    local region=$($CURL_BIN --connect-timeout 10 -s http://169.254.169.254/opc/v1/instance/ | jq -r .canonicalRegionName)
    local http_code=$($CURL_BIN -s -m 10 -o /dev/null -w '%{http_code}' "https://auth.${region}.oraclecloud.com/v1/x509")
    if [ "$http_code" == "000" ]; then
        echo "OCI API auth endpoint for region $region is not reachable"
        return 1
    fi
    return 0
}

function restore_oci_connectivity() {
    # the OCI API is unreachable when the instance has no public IP (e.g. a
    # boot that failed before one was attached); a secondary VNIC can appear
    # in instance metadata late, so re-check for one and route through it
    local secondary_ip=$($CURL_BIN --connect-timeout 10 -s http://169.254.169.254/opc/v1/vnics/ | jq -r '.[1].privateIp')
    if [ -z "$secondary_ip" ] || [ "$secondary_ip" == "null" ]; then
        echo "No secondary VNIC in metadata, unable to restore OCI API connectivity"
        return 1
    fi
    echo "Secondary VNIC with IP $secondary_ip found, configuring and routing through it to reach the OCI API"
    /usr/local/bin/secondary_vnic_all_configure_oracle.sh -c || return 1
    local secondary_device="$(ip addr | egrep '^[0-9]' | egrep -v 'lo|docker' | tail -1 | awk '{print $2}')"
    secondary_device="${secondary_device::-1}"
    secondary_device="$(echo $secondary_device | cut -d'@' -f1)"
    # replace any existing default routes with one via the secondary VNIC
    local default_route="$(ip route show | grep default -m 1)"
    while [ -n "$default_route" ]; do
        ip route delete $default_route || return 1
        default_route="$(ip route show | grep default -m 1)"
    done
    local nic2_route="default via "$(ip route show | grep $secondary_device | awk '{ print substr($1,1,index($1,"/")-2)1 " " $2 " " $3}' | head -1)
    ip route add $nic2_route
}

function default_terminate() {
    # retry in a loop rather than recursing: recursion eventually overflows
    # the stack and segfaults, silently ending the retries. The instance is
    # deliberately left RUNNING while retries continue so the autoscaler
    # counts it as untracked and an operator can intervene.
    while true; do
        if ! oci_api_reachable; then
            restore_oci_connectivity
        fi
        echo "Terminate the instance; we enable debug to have more details in case of oci cli failures"
        $OCI_BIN compute instance terminate --debug --instance-id "$INSTANCE_ID" --preserve-boot-volume false --auth instance_principal --force && break
        echo "Failed to terminate instance, sleeping 10 then retrying"
        sleep 10
    done
}

# now terminate our instance
default_terminate
