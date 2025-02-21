#!/bin/bash
cp /usr/local/bin/*.jar /usr/bin
cp /etc/jitsi/jibri/* /config
cp /opt/vo-meet-agent/vo-meet-agent-config.yml /etc/vo-meet-agent/vo-meet-agent-config.yml
chown -R jibri:jibri /etc/vo-meet-agent/vo-meet-agent-config.yml
