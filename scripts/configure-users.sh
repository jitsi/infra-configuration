#!/bin/bash

# e.g. ../all/bin/terraform/standalone

ansible-playbook -v -i "127.0.0.1," -c local ansible/configure-users.yml --vault-password-file .vault-password.txt
