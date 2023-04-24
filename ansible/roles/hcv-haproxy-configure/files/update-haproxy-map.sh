#!/bin/bash
#
# read a haproxy map file and uses haproxy admin socket to update the live configuration

function logit() {
  echo "## $1"
  logger -p local0.notice -t ${0##*/}[$$] "$1"
}
logit "starting update-haproxy-map.sh"

if [ -n "$1" ]; then
    UPDATE_MAP=$1
fi

if [ -z "$UPDATE_MAP" ]; then
  logit "no UPDATE_MAP found, exiting..."
  exit 1
fi

if [ ! -f "$UPDATE_MAP" ]; then
    logit "map file $UPDATE_MAP does not exist"
    exit 1
fi

logit "updating live config with $UPDATE_MAP"

PREPARE_VERSION=$(echo "prepare map $UPDATE_MAP" | socat /var/run/haproxy/admin.sock stdio | cut -d ':' -f2 | xargs)

echo "clear map $UPDATE_MAP" | socat /var/run/haproxy/admin.sock stdio

while IFS='' read -r line || [ -n "$line" ]; do
    echo "add map @$PREPARE_VERSION $UPDATE_MAP $line" | socat /var/run/haproxy/admin.sock stdio
done < "${UPDATE_MAP}"

echo "commit map @$PREPARE_VERSION $UPDATE_MAP" | socat /var/run/haproxy/admin.sock stdio
if [ $? -ne 0 ]; then
    logit "commit map failed for $UPDATE_MAP"
    echo -n "jitsi.haproxy.map_update_failed:1|c" | nc -4u -w1 localhost 8125
    exit 1
fi

echo -n "jitsi.haproxy.map_update:1|c" | nc -4u -w1 localhost 8125
