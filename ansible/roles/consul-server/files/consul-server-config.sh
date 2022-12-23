#!/bin/bash

if [ -z "$DATACENTER" ]; then
    echo "No DATACENTER environment variable, exiting..."
    exit 1
fi

if [ -z "$SERVER_ENV" ]; then
    echo "No SERVER_ENV environment variable, exiting..."
    exit 1
fi
if [ -z "$ENC_KEY" ]; then
    echo "No ENC_KEY environment variable, exiting..."
    exit 1
fi

CONSUL_CONFIG_PATH="/etc/consul.d/consul.hcl"

if [ ! -f "$CONSUL_CONFIG_PATH" ]; then
    echo "Consul config file $CONSUL_CONFIG_PATH not found, exiting..."
fi

sed -i "s#REPLACE_DATACENTER#$DATACENTER#g" $CONSUL_CONFIG_PATH
sed -i "s#REPLACE_ENC_KEY#$ENC_KEY#g" $CONSUL_CONFIG_PATH
sed -i "s#REPLACE_SERVER_ENV#$SERVER_ENV#g" $CONSUL_CONFIG_PATH