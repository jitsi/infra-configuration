#!/bin/bash
#
# check a draft haproxy config and install if it's valid

[ -z "$TEMPLATE_LOGDIR" ] && TEMPLATE_LOGDIR="/tmp/ct-logs"
[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="$TEMPLATE_LOGDIR/template.log"

if [ ! -d "$TEMPLATE_LOGDIR" ]; then
  mkdir $TEMPLATE_LOGDIR
fi

if [ ! -f "$TEMPLATE_LOGFILE" ]; then
  touch $TEMPLATE_LOGFILE
fi

TIMESTAMP=$(date --utc +%Y-%m-%d_%H:%M:%S.Z)

echo "$TIMESTAMP starting check-install-haproxy-config.sh" >> $TEMPLATE_LOGFILE

if [ -n "$1" ]; then
    DRAFT_CONFIG=$1
fi

if [ -z "$DRAFT_CONFIG" ]; then
  echo "#### cihc: no DRAFT_CONFIG found, exiting..." >> $TEMPLATE_LOGFILE
  exit 1
fi

if [ ! -f "$DRAFT_CONFIG" ]; then
    echo "#### cihc: draft haproxy config file $DRAFT_CONFIG does not exist" >> $TEMPLATE_LOGFILE
    exit 1
fi

# always emit at least a 0 to metrics
echo -n "jitsi.haproxy.reconfig:0|c" | nc -4u -w1 localhost 8125

FINAL_EXIT=0
haproxy -c -f "$DRAFT_CONFIG" >/dev/null
if [ $? -gt 0 ]; then
    echo "#### cihc: new haproxy config failed to validate" >> $TEMPLATE_LOGFILE
    FINAL_EXIT=1
fi

# skip id DRY_RUN is set
if [ "$DRY_RUN" == "false" ]; then
    echo "#### chic: in DRY_RUN mode" >> $TEMPLATE_LOGFILE
fi

if [ $FINAL_EXIT -eq 0 ]; then
    diff $DRAFT_CONFIG /etc/haproxy/haproxy.cfg
    if [ $? -gt 0 ]; then
        echo "#### cihc: validated $DRAFT_CONFIG; copy to haproxy.cfg and reload haproxy" >> $TEMPLATE_LOGFILE

        # save a copy of the new config
        cp "$DRAFT_CONFIG" $TEMPLATE_LOGDIR/$TIMESTAMP-haproxy.cfg
        if [ "$DRY_RUN" == "false" ]; then
            cp "$DRAFT_CONFIG" /etc/haproxy/haproxy.cfg
            if [ $? -gt 0 ]; then
                echo "#### chic: failed to copy the new haproxy config file to /etc/haproxy" >> $TEMPLATE_LOGFILE
                FINAL_EXIT=1
            else
                service haproxy reload
                if [ $? -gt 0 ]; then
                    echo "#### chic: failed to reload haproxy service" >> $TEMPLATE_LOGFILE
                    FINAL_EXIT=1
                else
                    echo -n "jitsi.haproxy.reconfig:1|c" | nc -4u -w1 localhost 8125
                    echo "#### chic: succeeded to reload haproxy with new config" >> $TEMPLATE_LOGFILE
                fi
            fi
        else
            echo "#### cihc: validated $DRAFT_CONFIG; but DRY_RUN is not false, re-run with DRY_RUN=false to apply" >> $TEMPLATE_LOGFILE
        fi
    else 
        echo "#### cihc: validated $DRAFT_CONFIG; but new is the same as the old" >> $TEMPLATE_LOGFILE
    fi
fi

# clean config directory
find $TEMPLATE_LOGDIR -type f -mtime +14 -name '*.cfg' -execdir rm -- '{}' \;

if [ $FINAL_EXIT -gt 0 ]; then
    echo -n "jitsi.haproxy.reconfig_failed:1|c" | nc -4u -w1 localhost 8125
else
    echo -n "jitsi.haproxy.reconfig_failed:0|c" | nc -4u -w1 localhost 8125
fi
