#!/bin/bash

# e.g. ../all/bin/terraform/standalone

ansible-playbook -v -i "127.0.0.1," -c local ansible/configure-users.yml -e '{ssh_ops_account_flag: false}' --vault-password-file .vault-password.txt
