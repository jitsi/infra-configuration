#! /bin/bash

AWS_CACHE_BIN="/usr/local/bin/aws_cache.sh"
ORACLE_CACHE_BIN="/usr/local/bin/oracle_cache.sh"
if [ -e "$ORACLE_CACHE_BIN" ]; then
    . $ORACLE_CACHE_BIN
else
    . $AWS_CACHE_BIN
fi

CURL_BIN="/usr/bin/curl"
NC_BIN="/bin/nc"
STATUS_URL="http://localhost:8063/actuator/health"
STATUS_TIMEOUT=30
STATUS=$($CURL_BIN -s --max-time $STATUS_TIMEOUT $STATUS_URL | jq -r .status)
healthyValue=1
if [[ "$STATUS" == "UP" ]]; then
    healthyValue=0
fi

# send metrics to statsd
echo "egress.healthy:$healthyValue|g" | $NC_BIN -C -w 1 -u localhost 8125
