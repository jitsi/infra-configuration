#!/bin/bash
#
# read a haproxy map file and uses haproxy admin socket to update the live configuration

[ -z "$TEMPLATE_LOGDIR" ] && TEMPLATE_LOGDIR="/tmp/ct-logs"
[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="$TEMPLATE_LOGDIR/template.log"

if [ ! -f "$TEMPLATE_LOGDIR" ]; then
  touch $TEMPLATE_LOGDIR
fi

if [ ! -f "$TEMPLATE_LOGFILE" ]; then
  touch $TEMPLATE_LOGFILE
fi

echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) starting update-haproxy-map.sh" >> $TEMPLATE_LOGFILE

if [ -n "$1" ]; then
    UPDATE_MAP=$1
fi

if [ -z "$UPDATE_MAP" ]; then
  echo "#### uhm: no UPDATE_MAP found, exiting..." >> $TEMPLATE_LOGFILE
  exit 1
fi

if [ ! -f "$UPDATE_MAP" ]; then
    echo "#### uhm: map file $UPDATE_MAP does not exist" >> $TEMPLATE_LOGFILE
    exit 1
fi

echo "#### uhm: updating live config of $UPDATE_MAP" >> $TEMPLATE_LOGFILE

PREPARE_VERSION=$(echo "prepare map $UPDATE_MAP" | socat /var/run/haproxy/admin.sock stdio | cut -d ':' -f2 | xargs)

echo "clear map $UPDATE_MAP" | socat /var/run/haproxy/admin.sock stdio

while IFS='' read -r line || [ -n "$line" ]; do
    echo "add map @$PREPARE_VERSION $UPDATE_MAP $line" | socat /var/run/haproxy/admin.sock stdio
done < "${UPDATE_MAP}"

echo "commit map @$PREPARE_VERSION $UPDATE_MAP" | socat /var/run/haproxy/admin.sock stdio
if [ $? -gt 0 ]; then
    echo "#### uhm: commit map failed for $UPDATE_MAP" >> $TEMPLATE_LOGFILE
    echo -n "jitsi.haproxy.map_update_failed:1|c" | nc -4u -w1 localhost 8125
    exit 1
else
    echo -n "jitsi.haproxy.map_update_failed:1|0" | nc -4u -w1 localhost 8125
    echo "#### uhm: failed to update map $UPDATE_MAP" >> $TEMPLATE_LOGFILE
fi

echo -n "jitsi.haproxy.map_update:1|c" | nc -4u -w1 localhost 8125

echo "#### uhm: succeeded to update $UPDATE_MAP" >> $TEMPLATE_LOGFILE
