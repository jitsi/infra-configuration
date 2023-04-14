#!/bin/bash
#
# check a draft haproxy config and install if it's valid

echo "## starting check-install-haproxycfg.sh"

if [ -n "$1" ]; then
    DRAFT_CONFIG=$1
fi

if [ -z "$DRAFT_CONFIG" ]; then
  echo "## check_install_haproxycfg.sh: no DRAFT_CONFIG found, exiting..."
  exit 1
fi

if [ ! -f "$DRAFT_CONFIG" ]; then
    echo -e "## check_install_haproxycfg.sh: draft haproxy config file ${DRAFT_CONFIG} does not exist"
    exit 1 
fi

haproxy -c -f "$DRAFT_CONFIG" >/dev/null
if [ $? -ne 0]; then
    echo "## check_install_haproxycfg.sh: new haproxy config failed, exiting..."
    exit 1
fi

echo "## validated $DRAFT_CONFIG; copying to haproxy.cfg and restarting haproxy"

cp $DRAFT_CONFIG /etc/haproxy/haproxy.cfg
service haproxy restart
