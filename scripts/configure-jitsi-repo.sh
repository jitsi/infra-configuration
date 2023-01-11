#!/bin/bash

# e.g. ../all/bin/terraform/standalone
LOCAL_PATH=$(dirname "${BASH_SOURCE[0]}")

ansible-playbook -i "127.0.0.1," -c local "$LOCAL_PATH/../ansible/configure-jitsi-repo.yml"
