#!/bin/bash
#set -x

# Get the COUNT largest conferences on the local bridge (by local endpoint count) and resolve their shards by
# querying config.js.
COUNT="${1:-5}"
curl -s 0:8080/debug  | jq -r '.conferences | to_entries | map({name: .value.name, endpoints_count: (.value.endpoints | length)}) | sort_by(.endpoints_count) | reverse | .[] | "\(.name) \(.endpoints_count)"' | head -$COUNT | \
while IFS= read -r line; do
  conference=`echo $line | sed -e 's/@.*//'`
  tenant=`echo $line | sed -e 's/.*@//' -e 's/conference\.//' -e 's/\..*$//'`
  eps=`echo $line | awk '{print $2}'`
  if [ -z $tenant ] ;then
    domain=`echo $line | awk '{print $1}' | sed -e 's/.*[\.@]conference\.//'`
    shardUrl="https://$domain/_unlock?room=$conference"
  else
    domain=`echo $line | awk '{print $1}' | sed -e 's/.*[\.@]conference\.'$tenant'\.//'`
    shardUrl="https://$domain/$tenant/_unlock?room=$conference"
    fi
  shard="$(curl -D - -s "$shardUrl" -o /dev/null | awk '/x-jitsi-shard/ {print $2}' | tr -d '\r' )"
  printf '%s/%s/%s\t%s\t%s\n' "$domain" "$tenant" "$conference" "$shard" "$eps"
done 
