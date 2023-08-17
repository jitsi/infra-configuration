#!/bin/bash

curl -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/metadata/user_data | base64 --decode > ~/postinstall.sh
chmod +x ~/postinstall.sh
~/postinstall.sh
