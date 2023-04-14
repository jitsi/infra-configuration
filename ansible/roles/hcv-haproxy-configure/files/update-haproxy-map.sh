#!/bin/bash
#
# read a haproxy map file and uses haproxy admin socket to update the live configuration

echo "## starting update-haproxy-map.sh"

if [ -n "$1" ]; then
    UPDATE_MAP=$1
fi

if [ -z "$UPDATE_MAP" ]; then
  echo "## update-haproxy-map.sh: no UPDATE_MAP found, exiting..."
  exit 1
fi

if [ ! -f "$UPDATE_MAP" ]; then
    echo -e "## update-haproxy-map.sh: map file ${UPDATE_MAP} does not exist"
    exit 1
fi

echo "## updating live config with $UPDATE_MAP"

PREPARE_VERSION=$(echo "prepare map $UPDATE_MAP" | socat /var/run/haproxy/admin.sock stdio | cut -d ':' -f2 | xargs)

echo "clear map $UPDATE_MAP" | socat /var/run/haproxy/admin.sock stdio
if [ $? -ne 0]; then
    echo "## check_install_haproxycfg.sh: new haproxy config failed, exiting..."
    exit 1
fi

while IFS='' read -r line || [ -n "$line" ]; do
    echo "add map @$PREPARE_VERSION $UPDATE_MAP $line" | socat /var/run/haproxy/admin.sock stdio
done < "${UPDATE_MAP}"

echo "commit map @$PREPARE_VERSION $UPDATE_MAP" | socat /var/run/haproxy/admin.sock stdio