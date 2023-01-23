#!/bin/bash

#rebuild the configuration files and signal new shards to jigasi
CONFIGURE_ONLY=true ANSIBLE_TAGS="setup,jigasi" /usr/local/bin/configure-jigasi-local.sh
exit $?