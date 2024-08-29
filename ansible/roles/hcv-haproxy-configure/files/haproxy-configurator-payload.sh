#!/bin/bash

# payload of the haproxy-configurator, assumed to be an operation protected by a consul lock

echo -n "jitsi.haproxy.reconfig_locked:1|c" | nc -4u -w1 localhost 8125

if [ -n "$1" ]; then
    TEMPLATE_LOGFILE=$1
else
    echo "## hc: missing TEMPLATE_LOGFILE, exiting"
    exit 1
fi

function timestamp() {
  echo $(date --utc +%Y-%m-%d_%H:%M:%S.Z)
}

function log_msg() {
  echo "$(timestamp) [$$] hap-cfg-payload: $1" | tee -a $TEMPLATE_LOGFILE
}

log_msg "entered haproxy-configurator-payload.sh"

if [ -n "$2" ]; then
    DRAFT_CONFIG_VALIDATED=$2
else
    log_msg "missing DRAFT_CONFIG_VALIDATED, exiting"
    FINAL_EXIT=1
fi

diff $DRAFT_CONFIG_VALIDATED /etc/haproxy/haproxy.cfg
if [ $? -eq 0 ]; then
    log_msg "the validated draft config is identical to the installed config; skipping"
    exit 0
fi

# copy the validated config to the real config
cp $DRAFT_CONFIG_VALIDATED /etc/haproxy/haproxy.cfg

log_msg "draining from load balancer"
/usr/local/bin/oci-lb-backend-drain.sh $TEMPLATE_LOGFILE
if [ $? -gt 0 ]; then
    log_msg "haproxy failed to drain from the load balancer"
    FINAL_EXIT=1
fi

if [[ "$FINAL_EXIT" -eq 0 ]]; then
    log_msg "reloading haproxy"

    # make sure the most recent validated config is being used
    cp $DRAFT_CONFIG_VALIDATED /etc/haproxy/haproxy.cfg

    service haproxy reload
    if [[ $? -gt 0 ]]; then
        log_Msg "haproxy failed to reload"
        echo -n "jitsi.haproxy.reconfig:0|c" | nc -4u -w1 localhost 8125
        FINAL_EXIT=1
    else
        echo -n "jitsi.haproxy.reconfig:1|c" | nc -4u -w1 localhost 8125
    fi
fi

# undrain the haproxy from the load balancer
log_msg "undraining from load balancer"
DRAIN_STATE="false" /usr/local/bin/oci-lb-backend-drain.sh $TEMPLATE_LOGFILE
if [[ $? -gt 0 ]] && [[ "$FINAL_EXIT" -eq 0 ]]; then
    log_msg "failed to undrain the load balancer"
    FINAL_EXIT=1
fi

# log that a reconfigure happened
log_msg "reloaded haproxy with new config"

# copy the live config over test config and kick off consul-template to make sure there are not any new changes
diff /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.test
if [ $? -ne 0 ]; then
    log_msg "live config is different than test config; reloading consul-template"
    cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.test
    service consul-template reload
    if [[ $? -gt 0 ]]; then
        log_Msg "consul-template failed to reload"
        FINAL_EXIT=1
    fi
fi

if [[ $FINAL_EXIT -gt 0 ]]; then
    echo -n "jitsi.haproxy.reconfig_failed:1|c" | nc -4u -w1 localhost 8125
    exit 1
else
    echo -n "jitsi.haproxy.reconfig_failed:0|c" | nc -4u -w1 localhost 8125
fi

exit $FINAL_EXIT