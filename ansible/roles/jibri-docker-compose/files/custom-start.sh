#!/bin/bash
apt-get -y update && apt-get -y install python3-pip python3-venv
python3 -m venv /opt/oci-cli-venv && /opt/oci-cli-venv/bin/pip install oci-cli && ln -sf /opt/oci-cli-venv/bin/oci /usr/local/bin/oci
cp /usr/local/bin/*.jar /usr/bin
cp /etc/jitsi/jibri/* /config
mkdir -p /etc/jitsi
cp /opt/vo-meet-agent/vo-meet-agent-config.yml /etc/jitsi/vo-meet-agent-config.yml
chown -R jibri:jibri /etc/jitsi/vo-meet-agent-config.yml
