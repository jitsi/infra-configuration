#!/bin/bash
# Get the COUNT largest conferences on the local bridge (by local endpoint count) and resolve their shards by
# querying config.js.
COUNT="${1:-5}"

curl -s 0:8080/debug  | jq -r '.conferences | to_entries | map({name: .value.name, endpoints_count: (.value.endpoints | length)}) | sort_by(.endpoints_count) | reverse | .[] | "\(.name) \(.endpoints_count)"' | head -$COUNT | \
while IFS= read -r line; do
  conference=`echo $line | sed -e 's/@.*//'`
  tenant=`echo $line | sed -e 's/.*@//' -e 's/conference\..*//' -e 's/\.$//'`
  eps=`echo $line | awk '{print $2}'`
  domain=`echo $line | awk '{print $1}' | sed -e 's/.*[\.@]conference\.//'`
  if [ -z $tenant ] ;then
    configJsUrl="https://$domain/config.js?room=$conference"
  else 
    configJsUrl="https://$domain/$tenant/config.js?room=$conference"
  fi
  shard=$( (curl -s "$configJsUrl"; echo "console.log(config.deploymentInfo.shard)") | node - )
  echo "$domain/$tenant/$conference\t$shard\t$eps"
done 
