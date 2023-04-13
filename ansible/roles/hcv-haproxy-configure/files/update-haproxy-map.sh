#!/bin/bash
#
# read a haproxy map file and uses haproxy admin socket to update the live configuration

if [ -z "$UPDATE_MAP" ]; then
  echo "no UPDATE_MAP found, exiting..."
  exit 1
fi

if [ ! -f "$UPDATE_MAP" ]; then
    echo -e "map file ${UPDATE_MAP} does not exist"
    exit 1 
fi

while IFS= read -r line; do
    echo "set map $UPDATE_MAP $line" | socat /var/run/haproxy/admin.sock stdio
done <<< "$UPDATE_MAP"
