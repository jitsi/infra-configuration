#!/bin/bash
cp /usr/local/bin/*.jar /usr/bin
cp /etc/jitsi/jibri/* /config
mkdir -p /etc/vo-meet-agent
cp /opt/vo-meet-agent/vo-meet-agent-config.yml /etc/vo-meet-agent/vo-meet-agent-config.yml
chown -R jibri:jibri /etc/vo-meet-agent/vo-meet-agent-config.yml
