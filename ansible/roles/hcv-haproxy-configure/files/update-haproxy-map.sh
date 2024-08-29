#!/bin/bash
#
# read a haproxy map file and uses haproxy admin socket to update the live configuration

[ -z "$TEMPLATE_LOGDIR" ] && TEMPLATE_LOGDIR="/var/log/consul-template"
[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="$TEMPLATE_LOGDIR/haproxy-template.log"

if [ ! -d "$TEMPLATE_LOGDIR" ]; then
  mkdir $TEMPLATE_LOGDIR
fi

if [ ! -f "$TEMPLATE_LOGFILE" ]; then
  touch $TEMPLATE_LOGFILE
fi

function timestamp() {
  echo $(date --utc +%Y-%m-%d_%H:%M:%S.Z)
}

function log_msg() {
  echo "$(timestamp) [$$] hap-map: $1" | tee -a $TEMPLATE_LOGFILE
}

log_msg "starting update-haproxy-map.sh"

if [ -n "$1" ]; then
    UPDATE_MAP=$1
fi

if [ -z "$UPDATE_MAP" ]; then
  log_msg "no UPDATE_MAP found, exiting..."
  exit 1
fi

if [ ! -f "$UPDATE_MAP" ]; then
    log_msg "map file $UPDATE_MAP does not exist"
    exit 1
fi

log_msg "updating live config of $UPDATE_MAP"

PREPARE_VERSION=$(echo "prepare map $UPDATE_MAP" | socat /var/run/haproxy/admin.sock stdio | cut -d ':' -f2 | xargs)

echo "clear map $UPDATE_MAP" | socat /var/run/haproxy/admin.sock stdio

while IFS='' read -r line || [ -n "$line" ]; do
    echo "add map @$PREPARE_VERSION $UPDATE_MAP $line" | socat /var/run/haproxy/admin.sock stdio
done < "${UPDATE_MAP}"

echo "commit map @$PREPARE_VERSION $UPDATE_MAP" | socat /var/run/haproxy/admin.sock stdio
if [ $? -gt 0 ]; then
    log_msg "commit map failed for $UPDATE_MAP"
    echo -n "jitsi.haproxy.map_update_failed:1|c" | nc -4u -w1 localhost 8125
    exit 1
else
    echo -n "jitsi.haproxy.map_update_failed:0|c" | nc -4u -w1 localhost 8125
fi

echo -n "jitsi.haproxy.map_update:1|c" | nc -4u -w1 localhost 8125

log_msg "succeeded to update $UPDATE_MAP" >> $TEMPLATE_LOGFILE
