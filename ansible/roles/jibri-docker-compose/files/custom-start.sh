#!/bin/bash
cp /usr/local/bin/*.jar /usr/bin
cp /etc/jitsi/jibri/* /config
mkdir -p /etc/jitsi
cp /opt/vo-meet-agent/vo-meet-agent-config.yml /etc/jitsi/vo-meet-agent-config.yml
chown -R jibri:jibri /etc/vo-meet-agent/vo-meet-agent-config.yml
